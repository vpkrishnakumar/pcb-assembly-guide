#!/usr/bin/env python3
"""PCB Assembly Guide, command-line edition for Linux, Windows and macOS.

Reads a KiCad board (.kicad_pcb) and writes the step-by-step hand-assembly guide as a single
web page, then opens it in your browser. Needs Python 3.8+ and nothing else; with KiCad installed
the page shows the board in 3D, without it the parts are drawn as simple boxes.

    python3 pcb_assembly_guide.py board.kicad_pcb

This mirrors the logic of the Mac app (Sources/PCBAssemblyGuide); keep the two in step.
"""
from __future__ import annotations

import argparse
import base64
import glob
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import webbrowser
from functools import cmp_to_key
from pathlib import Path

# ---------------------------------------------------------------------------------------------
# S-expressions: an atom is a str, a list is a Python list.

_TOKEN = re.compile(rb'[ \t\r\n]*(\(|\)|"(?:[^"\\]|\\.)*"?|[^ \t\r\n()]+)', re.S)
_PAREN = re.compile(rb'\(|\)|"(?:[^"\\]|\\.)*"?', re.S)
_ESCAPE = re.compile(rb"\\(.)", re.S)
_NUMBER = re.compile(r"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$")
# Sub-lists that are large and irrelevant to us (pre-rendered text outlines).
_SKIPPED = (b"render_cache",)


def _atom(token):
    if token.startswith(b'"'):
        body = token[1:-1] if len(token) > 1 and token.endswith(b'"') else token[1:]
        body = _ESCAPE.sub(lambda m: b"\n" if m.group(1) == b"n" else m.group(1), body)
        return body.decode("utf-8", "replace")
    return token.decode("utf-8", "replace")


def _skip_list(data, start):
    """With `start` on an opening paren, returns the offset just past the matching closing paren."""
    depth = 0
    for match in _PAREN.finditer(data, start):
        token = match.group(0)
        if token == b"(":
            depth += 1
        elif token == b")":
            depth -= 1
            if depth == 0:
                return match.end()
    return len(data)


def _parse_list(data, pos):
    """Parses a list whose opening paren has just been consumed. Returns (list, offset past its end)."""
    stack = [[]]
    while True:
        match = _TOKEN.match(data, pos)
        if not match:
            break
        token = match.group(1)
        pos = match.end()
        if token == b"(":
            head = _TOKEN.match(data, pos)
            if head and head.group(1) in _SKIPPED:
                pos = _skip_list(data, match.start(1))
                continue
            stack.append([])
        elif token == b")":
            done = stack.pop()
            if not stack:
                return done, pos
            stack[-1].append(done)
        else:
            stack[-1].append(_atom(token))
    while len(stack) > 1:
        done = stack.pop()
        stack[-1].append(done)
    return stack[0], pos


def top_level_lists(data, names):
    """Every direct child list of the root whose head is in `names`, with the offset of its closing paren."""
    wanted = {name.encode() for name in names}
    out = []
    match = _TOKEN.match(data, 0)
    if not match or match.group(1) != b"(":
        return out
    pos = match.end()
    while True:
        match = _TOKEN.match(data, pos)
        if not match or match.group(1) == b")":
            break
        if match.group(1) == b"(":
            head = _TOKEN.match(data, match.end())
            if head and head.group(1) in wanted:
                expr, pos = _parse_list(data, match.end())
                out.append((expr, pos - 1))
            else:
                pos = _skip_list(data, match.start(1))
        else:
            pos = match.end()
    return out


def head(expr):
    return expr[0] if isinstance(expr, list) and expr and isinstance(expr[0], str) else None


def args(expr):
    return [item for item in expr[1:] if isinstance(item, str)] if isinstance(expr, list) else []


def numbers(expr):
    return [float(a) for a in args(expr) if _NUMBER.match(a)]


def child(expr, name):
    for item in expr:
        if head(item) == name:
            return item
    return None


def children(expr, name):
    return [item for item in expr if head(item) == name]


# ---------------------------------------------------------------------------------------------
# Board model


class Pad:
    def __init__(self, name, x, y, half_width, half_height, net, function):
        self.name, self.x, self.y = name, x, y
        self.half_width, self.half_height = half_width, half_height
        self.net, self.function = net, function


class Box:
    def __init__(self, min_x=math.inf, min_y=math.inf, max_x=-math.inf, max_y=-math.inf):
        self.min_x, self.min_y, self.max_x, self.max_y = min_x, min_y, max_x, max_y

    @property
    def valid(self):
        return self.min_x <= self.max_x and self.min_y <= self.max_y

    def add(self, x, y):
        self.min_x, self.max_x = min(self.min_x, x), max(self.max_x, x)
        self.min_y, self.max_y = min(self.min_y, y), max(self.max_y, y)

    def add_point(self, values):
        if values is not None and len(values) >= 2:
            self.add(values[0], values[1])

    def copy(self):
        return Box(self.min_x, self.min_y, self.max_x, self.max_y)


POLARITY_LABEL = {"diode": "K", "led": "K", "positive": "+", "pin1": "1", "connector": "1"}
POLARITY_TITLE = {
    "diode": "Polarised: cathode (K) at the red dot",
    "led": "Polarised: cathode (K) at the red dot",
    "positive": "Polarised: positive (+) at the red dot",
    "pin1": "Pin 1 at the red dot",
    "connector": "Pin 1 at the red dot",
}
POLARITY_DETAIL = {
    "diode": "The cathode end of the part has a line or band. Put the band towards the red dot.",
    "led": "The cathode is marked by a green dot or line on top, or by the bar of the T / point of the arrow "
           "underneath. If unsure, use a multimeter in diode mode: the LED lights with the black probe on the cathode.",
    "positive": "Tantalum: the stripe is +, so it goes at the red dot. Aluminium can: the stripe is \u2212, "
                "so it goes away from the red dot.",
    "pin1": "Find the dot, dimple or notch on the package and put that corner at the red dot.",
    "connector": "Turn the housing to match the 3D view. Pin 1 is at the red dot.",
}

_CHIP_SIZE = re.compile(r"(?<![0-9])(01005|0201|0402|0603|0805|1206|1210|1806|1812|2010|2512)(?![0-9])")
_PACKAGE = re.compile(
    r"(?i)(SOT-?[0-9]+(-[0-9]+)?|SOD-?[0-9]+[A-Z]*|SOIC-?[0-9]+|T?SSOP-?[0-9]+|MSOP-?[0-9]+|SOP-?[0-9]+(?![0-9P])"
    r"|[LT]?QFP-?[0-9]+|[A-Z]?QFN-?[0-9]+|DFN-?[0-9]+|WSON(-[0-9]+)?(?!x)|BGA-?[0-9]+|TO-?[0-9]+|DO-?[0-9]+[A-Z]*"
    r"|SM[ABC](?![A-Z]))"
)
_BIDIRECTIONAL_TVS = re.compile(r"^(SM[A-D]J|SMF|P[46]KE|1\.5KE)[0-9.]+CA", re.I)
_JUMPER = re.compile(r"(?i)pads?\s*[A-Za-z0-9]+\s*-\s*[A-Za-z0-9]+")
KIND_NAMES = {
    "RN": "Resistor array", "C": "Capacitor", "L": "Inductor", "FB": "Ferrite bead", "LED": "LED", "U": "IC",
    "IC": "IC", "Q": "Transistor", "J": "Connector", "P": "Connector", "CN": "Connector", "Y": "Crystal",
    "X": "Crystal", "SW": "Switch", "S": "Switch", "F": "Fuse",
}


def is_bidirectional_tvs(value):
    """TVS part numbers such as SMBJ6.0CA: the "CA" suffix means bidirectional, so orientation is free."""
    return bool(_BIDIRECTIONAL_TVS.search(value))


def ref_prefix(ref):
    letters = ""
    for ch in ref:
        if not ch.isalpha():
            break
        letters += ch
    return letters.upper()


class Component:
    """One footprint that has to be soldered. Board coordinates are KiCad's: mm, X right, Y down."""

    def board_point(self, lx, ly):
        a = self.rotation * math.pi / 180
        return (self.x + lx * math.cos(a) + ly * math.sin(a), self.y - lx * math.sin(a) + ly * math.cos(a))

    @property
    def center(self):
        return self.board_point((self.min_x + self.max_x) / 2, (self.min_y + self.max_y) / 2)

    @property
    def width(self):
        return self.max_x - self.min_x

    @property
    def depth(self):
        return self.max_y - self.min_y

    @property
    def area(self):
        return self.width * self.depth

    @property
    def prefix(self):
        return ref_prefix(self.ref)

    @property
    def is_ic(self):
        return self.prefix in ("U", "IC")

    @property
    def is_led(self):
        return self.prefix == "LED" or "LED" in self.footprint.upper() or "LED" in self.value.upper()

    @property
    def is_reversible(self):
        return self.polarity is None and self.pad_count == 2

    @property
    def reversible_note(self):
        return ("Bidirectional TVS: fits either way round" if is_bidirectional_tvs(self.value)
                else "Not polarised: fits either way round")

    @property
    def kind_name(self):
        prefix = self.prefix
        if prefix == "R":
            return "Resistor" if self.jumper is None else "Jumper link"
        if prefix == "D":
            return "LED" if self.is_led else "Diode"
        return KIND_NAMES.get(prefix, "Part")

    @property
    def chip_size(self):
        match = _CHIP_SIZE.search(self.footprint)
        return match.group(0) if match else None

    @property
    def size_label(self):
        if self.chip_size:
            return self.chip_size
        match = _PACKAGE.search(self.footprint)
        return match.group(0) if match else None

    @property
    def dimensions(self):
        return "%.1f \u00d7 %.1f mm" % (max(self.width, self.depth), min(self.width, self.depth))

    @property
    def nets(self):
        seen, out = set(), []
        for pad in self.pads:
            if pad.net and pad.name not in seen:
                seen.add(pad.name)
                out.append([pad.name, pad.net])
        return out


def polarity_mark(prefix, footprint, value, pads):
    """Works out which pad fixes the orientation. Returns (kind, pad, confirmed) or None."""
    pad_names = {pad.name for pad in pads}
    first = next((pad for pad in pads if pad.name in ("1", "A1")), None)
    is_led = prefix == "LED" or "LED" in footprint.upper() or "LED" in value.upper()

    if len(pad_names) == 2:
        if is_bidirectional_tvs(value):
            return None
        # Schematic pin names are the reliable source for two-terminal parts.
        cathode = next((pad for pad in pads if pad.function in ("K", "CATHODE", "KATHODE", "CATH")), None)
        if cathode:
            return ("led" if is_led else "diode", cathode, True)
        plus = next((pad for pad in pads if pad.function in ("+", "POS", "P+")), None)
        if plus:
            return ("positive", plus, True)
        minus = next((pad for pad in pads if pad.function in ("-", "NEG")), None)
        if minus:
            plus = next((pad for pad in pads if pad.name != minus.name), None)
            if plus:
                return ("positive", plus, True)
        if first is None:
            return None
        if prefix in ("D", "LED"):
            return ("led" if is_led else "diode", first, False)
        lower = footprint.lower()
        if prefix == "C" and (footprint.startswith("CP_") or "elec" in lower or "tant" in lower):
            return ("positive", first, False)
        return None

    if first is None or len(pad_names) <= 2:
        return None
    if prefix in ("R", "C", "L", "FB", "F", "RN", "RV", "TP", "JP", "H", "MH", "SW", "S"):
        return None
    if prefix in ("J", "P", "CN"):
        return ("connector", first, True)
    return ("pin1", first, True)


def component_from(fp, end):
    if len(fp) <= 2:
        return None
    lib_id = fp[1] if isinstance(fp[1], str) else ""
    pieces = [piece for piece in lib_id.split(":") if piece]
    footprint = pieces[-1] if pieces else lib_id

    ref, value, layer = "", "", "F.Cu"
    x = y = rot = 0.0
    attrs = set()
    dnp = has_model = False
    fab, pad_box = Box(), Box()
    thru_count = 0
    pads = []
    properties = {}

    def on_fab(item):
        layer_item = child(item, "layer")
        names = args(layer_item) if layer_item is not None else []
        return bool(names) and names[0].endswith(".Fab")

    def point(item, name):
        found = child(item, name)
        return numbers(found) if found is not None else None

    for item in fp[2:]:
        kind = head(item)
        if kind == "layer":
            layer = (args(item) or [layer])[0]
        elif kind == "at":
            n = numbers(item)
            if len(n) >= 2:
                x, y = n[0], n[1]
            rot = n[2] if len(n) >= 3 else 0.0
        elif kind == "property":
            if len(item) >= 3 and isinstance(item[1], str) and isinstance(item[2], str):
                if item[1] == "Reference":
                    ref = item[2]
                if item[1] == "Value":
                    value = item[2]
                properties[item[1].upper()] = item[2]
        elif kind == "fp_text":
            if len(item) >= 3 and isinstance(item[1], str) and isinstance(item[2], str):
                if item[1] == "reference":
                    ref = item[2]
                if item[1] == "value":
                    value = item[2]
        elif kind == "attr":
            attrs = set(args(item))
        elif kind == "dnp":
            dnp = (args(item) or [None])[0] != "no"
        elif kind == "model":
            has_model = True
        elif kind == "pad":
            if len(item) < 3 or not isinstance(item[2], str) or item[2] == "np_thru_hole":
                continue
            at, size = point(item, "at"), point(item, "size")
            if at is None or len(at) < 2 or size is None or len(size) < 2:
                continue
            # A pad's stored angle includes the footprint's rotation.
            t = ((at[2] if len(at) >= 3 else 0.0) - rot) * math.pi / 180
            hw = (abs(size[0] * math.cos(t)) + abs(size[1] * math.sin(t))) / 2
            hh = (abs(size[0] * math.sin(t)) + abs(size[1] * math.cos(t))) / 2
            pad_box.add(at[0] - hw, at[1] - hh)
            pad_box.add(at[0] + hw, at[1] + hh)
            if item[2] == "thru_hole":
                thru_count += 1
            name = item[1] if isinstance(item[1], str) else ""
            if not name:
                continue
            # KiCad stores the schematic pin name as "<name>_<pad number>".
            function_item = child(item, "pinfunction")
            function = (args(function_item) or [""])[0] if function_item is not None else ""
            if function.endswith("_" + name):
                function = function[: -(len(name) + 1)]
            net_item = child(item, "net")
            net = (args(net_item) or [""])[-1] if net_item is not None else ""
            pads.append(Pad(name, at[0], at[1], hw, hh, net, function.upper()))
        elif kind in ("fp_line", "fp_rect"):
            if on_fab(item):
                fab.add_point(point(item, "start"))
                fab.add_point(point(item, "end"))
        elif kind == "fp_circle":
            c, e = point(item, "center"), point(item, "end")
            if on_fab(item) and c is not None and len(c) >= 2 and e is not None and len(e) >= 2:
                r = math.hypot(e[0] - c[0], e[1] - c[1])
                fab.add(c[0] - r, c[1] - r)
                fab.add(c[0] + r, c[1] + r)
        elif kind == "fp_poly":
            pts = child(item, "pts")
            if on_fab(item) and pts is not None:
                for p in children(pts, "xy"):
                    fab.add_point(numbers(p))

    # Skip things that are not soldered parts: logos, fiducials, mounting holes, DNP.
    if not ref or ref.startswith("#") or "*" in ref or not pads:
        return None
    if dnp or attrs & {"dnp", "board_only", "exclude_from_bom"}:
        return None

    body = fab
    if not body.valid or body.max_x - body.min_x < 0.05 or body.max_y - body.min_y < 0.05:
        body = pad_box
    if not body.valid:
        body = Box(-0.5, -0.5, 0.5, 0.5)

    # Some footprints draw the outline around the leads as well as the body. Where the outline reaches
    # past the centre of outward-pointing pads, the body really stops at their inner ends.
    if len(pads) > 4:
        trimmed = body.copy()
        p = max(pads, key=lambda pad: pad.x)
        if p.half_width > p.half_height * 1.2 and body.max_x > p.x:
            trimmed.max_x = p.x - p.half_width
        p = min(pads, key=lambda pad: pad.x)
        if p.half_width > p.half_height * 1.2 and body.min_x < p.x:
            trimmed.min_x = p.x + p.half_width
        p = max(pads, key=lambda pad: pad.y)
        if p.half_height > p.half_width * 1.2 and body.max_y > p.y:
            trimmed.max_y = p.y - p.half_height
        p = min(pads, key=lambda pad: pad.y)
        if p.half_height > p.half_width * 1.2 and body.min_y < p.y:
            trimmed.min_y = p.y + p.half_height
        if (trimmed.max_x - trimmed.min_x > (body.max_x - body.min_x) * 0.4
                and trimmed.max_y - trimmed.min_y > (body.max_y - body.min_y) * 0.4):
            body = trimmed

    # A link on a jumper footprint only covers the two pads named in its value, e.g. "0R (pads 2-3)".
    jumper = None
    reach_box = pad_box
    match = _JUMPER.search(value)
    if match:
        names = [n.strip() for n in re.sub(r"(?i)pads?\s*", "", match.group(0)).split("-") if n]
        if len(names) == 2 and names[0] != names[1]:
            a = next((pad for pad in pads if pad.name == names[0]), None)
            b = next((pad for pad in pads if pad.name == names[1]), None)
            if a and b:
                jumper = (a, b)
                body = Box()
                body.add(min(a.x, b.x) - 0.25, min(a.y, b.y) - 0.25)
                body.add(max(a.x, b.x) + 0.25, max(a.y, b.y) + 0.25)
                reach_box = Box()
                for p in (a, b):
                    reach_box.add(p.x - p.half_width, p.y - p.half_height)
                    reach_box.add(p.x + p.half_width, p.y + p.half_height)

    cx, cy = (body.min_x + body.max_x) / 2, (body.min_y + body.max_y) / 2
    reach = math.hypot(body.max_x - body.min_x, body.max_y - body.min_y) / 2
    if reach_box.valid:
        for px in (reach_box.min_x, reach_box.max_x):
            for py in (reach_box.min_y, reach_box.max_y):
                reach = max(reach, math.hypot(px - cx, py - cy))

    prefix = ref_prefix(ref)
    mark = polarity_mark(prefix, footprint, value, pads) if jumper is None else None
    polarity = None
    if mark:
        kind, pad, confirmed = mark
        a = rot * math.pi / 180
        polarity = {
            "kind": kind, "confirmed": confirmed, "local_x": pad.x, "local_y": pad.y,
            "x": x + pad.x * math.cos(a) + pad.y * math.sin(a),
            "y": y - pad.x * math.sin(a) + pad.y * math.cos(a),
        }

    def prop(keys):
        for key in keys:
            found = properties.get(key)
            if found is not None and found != "" and found != "~":
                return found
        return None

    c = Component()
    c.ref, c.value, c.footprint = ref, value, footprint
    c.is_bottom = layer.startswith("B.")
    c.x, c.y, c.rotation = x, y, rot
    c.is_tht = "through_hole" in attrs or ("smd" not in attrs and thru_count > 0 and thru_count * 2 >= len(pads))
    c.pad_count, c.pads = len(pads), pads
    c.min_x, c.min_y, c.max_x, c.max_y = body.min_x, body.min_y, body.max_x, body.max_y
    c.reach, c.polarity, c.jumper = reach, polarity, jumper
    c.datasheet = prop(["DATASHEET"])
    c.has_model, c.source_end = has_model, end
    return c


def read_components(data):
    """Every assembled footprint in the contents of a .kicad_pcb file."""
    seen, out = set(), []
    for expr, end in top_level_lists(data, ["footprint", "module"]):
        c = component_from(expr, end)
        if c is not None and c.ref not in seen:
            seen.add(c.ref)
            out.append(c)
    return out


# ---------------------------------------------------------------------------------------------
# Ordering


def numeric_compare(a, b):
    """Like a file manager: runs of digits compare by value, so R2 sorts before R10."""
    ta, tb = re.findall(r"[0-9]+|[^0-9]", a), re.findall(r"[0-9]+|[^0-9]", b)
    for x, y in zip(ta, tb):
        if x == y:
            continue
        if x[0].isdigit() and y[0].isdigit():
            xi, yi = int(x), int(y)
            if xi != yi:
                return -1 if xi < yi else 1
            if len(x) != len(y):
                return -1 if len(x) < len(y) else 1
            continue
        return -1 if x < y else 1
    return (len(ta) > len(tb)) - (len(ta) < len(tb))


STAGE_TITLES = ["Top \u00b7 SMD", "Bottom \u00b7 SMD", "Top \u00b7 Through-hole", "Bottom \u00b7 Through-hole"]
PRESETS = {  # stage indices in soldering order
    "smd-first": [0, 1, 2, 3],
    "smallest-first": [0, 1, 2, 3],
    "top-first": [0, 2, 1, 3],
    "bottom-first": [1, 3, 0, 2],
}


def stage_of(c):
    if c.is_tht:
        return 3 if c.is_bottom else 2
    return 1 if c.is_bottom else 0


def walk_order(members):
    """Orders identical parts so each one is next to the previous, starting top-left."""
    remaining = list(members)
    current = min(remaining, key=lambda c: c.x + c.y)
    remaining.remove(current)
    out = [current.ref]
    while remaining:
        nearest = min(remaining, key=lambda c: math.hypot(c.x - current.x, c.y - current.y))
        remaining.remove(nearest)
        current = nearest
        out.append(current.ref)
    return out


def assembly_plan(components, preset="smd-first"):
    """ICs first while the pads are easy to reach, then smallest body to largest, identical parts together."""
    rank = {stage: index for index, stage in enumerate(PRESETS[preset])}
    buckets = {}
    for c in components:
        buckets.setdefault((stage_of(c), c.value, c.footprint), []).append(c)

    def before(a, b):
        (stage_a, value_a, fp_a), (stage_b, value_b, fp_b) = a[0], b[0]
        ca, cb = a[1][0], b[1][0]
        if stage_a != stage_b:
            return rank[stage_a] < rank[stage_b]
        if preset != "smallest-first" and ca.is_ic != cb.is_ic:
            return ca.is_ic
        if abs(ca.area - cb.area) > 0.01:
            return ca.area < cb.area
        if value_a != value_b:
            return numeric_compare(value_a, value_b) < 0
        return fp_a < fp_b

    ordered = sorted(buckets.items(), key=cmp_to_key(lambda a, b: -1 if before(a, b) else (1 if before(b, a) else 0)))
    groups, steps, group_of_step = [], [], []
    for (stage, value, footprint), members in ordered:
        refs = walk_order(members)
        group = {"stage": STAGE_TITLES[stage], "value": value, "fp": footprint, "refs": refs}
        if members[0].size_label:
            group["size"] = members[0].size_label
        groups.append(group)
        group_of_step.extend([len(groups) - 1] * len(refs))
        steps.extend(refs)
    return groups, steps, group_of_step


def kit_rows(components):
    """One line per distinct value and footprint, grouped by kind of part."""
    buckets = {}
    for c in components:
        buckets.setdefault(c.value + "|" + c.footprint, []).append(c)
    rows = []
    for key, members in buckets.items():
        row = {"id": key, "kind": members[0].kind_name, "value": members[0].value, "fp": members[0].footprint,
               "refs": sorted((m.ref for m in members), key=cmp_to_key(numeric_compare))}
        if members[0].size_label:
            row["size"] = members[0].size_label
        rows.append(row)

    def compare(a, b):
        if a["kind"] != b["kind"]:
            return -1 if a["kind"] < b["kind"] else 1
        return numeric_compare(a["value"], b["value"]) or (a["fp"] > b["fp"]) - (a["fp"] < b["fp"])

    return sorted(rows, key=cmp_to_key(compare))


# ---------------------------------------------------------------------------------------------
# Markings


def ohms(value):
    """Parses values such as "10k", "4k7", "100R", "2.2M", "0R (pads 1-2)" into ohms."""
    tokens = [t for t in re.split(r"[ (/]", value) if t]
    if not tokens:
        return None
    t = tokens[0].upper().replace("\u03a9", "R").replace("\u2126", "R").replace("OHM", "R")
    multipliers = {"R": 1.0, "K": 1e3, "M": 1e6}

    def number(text):
        return float(text) if _NUMBER.match(text) else None

    index = next((i for i, ch in enumerate(t) if ch in multipliers), None)
    if index is None:
        return number(t)
    whole, fraction = t[:index], t[index + 1:]
    if not ((all(ch.isdigit() for ch in whole) or number(whole) is not None) and all(ch.isdigit() for ch in fraction)):
        return None
    if not whole and not fraction:
        return None
    parsed = number(whole or "0") if not fraction else number((whole or "0") + "." + fraction)
    return None if parsed is None else parsed * multipliers[t[index]]


def eia_code(value, digits):
    """EIA code with `digits` significant figures and a multiplier digit, e.g. 10 kΩ → "103" / "1002"."""
    if value <= 0:
        return "0"
    exponent = math.floor(math.log10(value)) - (digits - 1)
    if exponent < 0:
        # Below the smallest whole-number code, "R" marks the decimal point: 4.7 Ω → "4R7".
        text = ("%.*f" % (digits, value)).replace(".", "R")
        return (text[1:] if value < 1 else text)[: digits + 1]
    mantissa = int(math.floor(value / 10 ** exponent + 0.5))
    if mantissa >= 10 ** digits:
        mantissa //= 10
        exponent += 1
    return "%d%d" % (mantissa, exponent)


def marking_hint(c):
    """A short hint about the top marking to expect, or None when nothing useful can be said."""
    prefix = c.prefix
    if prefix == "R":
        value = ohms(c.value)
        if value is None:
            return None
        if value == 0:
            return "Marking: 0 or 000 (often unmarked at 0402 and below)."
        codes = "%s (5%%) or %s (1%%)" % (eia_code(value, 2), eia_code(value, 3))
        if (c.chip_size or "") in ("01005", "0201", "0402"):
            return "Usually unmarked at this size. If marked: %s." % codes
        return "Marking: %s." % codes
    if prefix == "RN":
        value = ohms(c.value)
        return None if value is None else "Marking: %s." % eia_code(value, 2)
    if prefix == "C":
        return "Ceramic capacitors are unmarked. Keep them in their labelled strip." if c.polarity is None else None
    if prefix in ("L", "FB"):
        return None
    if c.pad_count > 2 or c.polarity is not None:
        return "The top marking is often a short code, not the part number. Check the datasheet."
    return None


# ---------------------------------------------------------------------------------------------
# KiCad: finding it, borrowing library models, exporting the 3D board


def locate_kicad_cli():
    """The command (as an argument list) that runs kicad-cli, or None."""
    override = os.environ.get("KICAD_CLI")
    if override:
        return [override]
    for name in ("kicad-cli", "kicad.kicad-cli", "kicad-cli-nightly"):
        found = shutil.which(name)
        if found:
            return [found]
    candidates = []
    if sys.platform == "darwin":
        candidates.append("/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli")
        for directory in ("/Applications", os.path.expanduser("~/Applications")):
            for entry in sorted(glob.glob(os.path.join(directory, "[Kk]i[Cc]ad*"))):
                candidates += [entry + "/KiCad.app/Contents/MacOS/kicad-cli", entry + "/Contents/MacOS/kicad-cli"]
    elif os.name == "nt":
        for base in (os.environ.get("ProgramFiles", r"C:\Program Files"), os.environ.get("LOCALAPPDATA", "")):
            if base:
                candidates += sorted(glob.glob(os.path.join(base, "KiCad", "*", "bin", "kicad-cli.exe")), reverse=True)
                candidates += sorted(glob.glob(os.path.join(base, "Programs", "KiCad", "*", "bin", "kicad-cli.exe")),
                                     reverse=True)
    else:
        candidates += ["/usr/bin/kicad-cli", "/usr/local/bin/kicad-cli", "/snap/bin/kicad.kicad-cli"]
    for path in candidates:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return [path]
    if shutil.which("flatpak"):
        try:
            probe = subprocess.run(["flatpak", "info", "org.kicad.KiCad"], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=20)
            if probe.returncode == 0:
                return ["flatpak", "run", "--command=kicad-cli", "org.kicad.KiCad"]
        except (OSError, subprocess.SubprocessError):
            pass
    return None


def cache_directory():
    if sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Caches")
    elif os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    else:
        base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return Path(base) / "pcb-assembly-guide"


def model_library_root(cli):
    """KiCad's standard 3D model folder, if it is installed where this program can read it."""
    candidates = [os.environ.get("KICAD%d_3DMODEL_DIR" % v) for v in range(12, 5, -1)]
    if cli and cli[0] != "flatpak":
        binary = Path(os.path.realpath(cli[0]))
        candidates += [binary.parent.parent / "SharedSupport" / "3dmodels",  # macOS app bundle
                       binary.parent.parent / "share" / "kicad" / "3dmodels"]  # Windows, /usr, /usr/local
    candidates += ["/usr/share/kicad/3dmodels", "/usr/local/share/kicad/3dmodels"]
    candidates += sorted(glob.glob(os.path.expanduser("~/.local/share/kicad/*/3dmodels")), reverse=True)
    for candidate in candidates:
        if candidate and os.path.isdir(str(candidate)):
            return Path(str(candidate))
    return None


def model_index(root):
    """Every STEP model in the library, by lower-cased file name without extension."""
    index = {}
    if root is None:
        return index
    for directory in sorted(root.glob("*.3dshapes")):
        for file in sorted(directory.iterdir()):
            if file.name.lower().endswith(".step"):
                index[file.name[:-5].lower()] = str(file)
    return index


METRIC = {"01005": "0402", "0201": "0603", "0402": "1005", "0603": "1608", "0805": "2012",
          "1206": "3216", "1210": "3225", "1812": "4532", "2010": "5025", "2512": "6332"}


def library_model(c, index):
    """The library model for a part and the Z rotation that lines it up, or None when there is no safe match."""
    if c.has_model or c.jumper is not None:
        return None
    # A footprint named exactly like a library model is the same package.
    exact = index.get(c.footprint.lower())
    if exact:
        return exact, 0
    # Otherwise only two-pad chip parts, where the size code alone fixes the shape.
    size = c.chip_size
    if c.is_tht or len(c.pads) != 2 or not size or size not in METRIC:
        return None
    prefix = c.prefix
    if prefix == "C":
        family = "c" if c.polarity is None else ""
    elif prefix == "R":
        family = "r"
    elif prefix in ("L", "FB"):
        family = "l"
    elif prefix in ("D", "LED"):
        family = "led" if c.is_led else "d"
    else:
        family = ""
    path = index.get("%s_%s_%smetric" % (family, size, METRIC[size])) if family else None
    if not path:
        return None
    # Library models have pad 1 (the cathode on diodes and LEDs) on the −X side.
    if c.polarity:
        reference = (c.polarity["local_x"], c.polarity["local_y"])
    else:
        pad_one = next((pad for pad in c.pads if pad.name == "1"), None)
        if pad_one is None:
            return None
        reference = (pad_one.x, pad_one.y)
    vx = reference[0] - (c.pads[0].x + c.pads[1].x) / 2
    vy = reference[1] - (c.pads[0].y + c.pads[1].y) / 2
    # Footprints with pads stacked along Y would need a quarter turn, which is left to the plain box.
    if abs(vx) <= abs(vy):
        return None
    return path, (0 if vx < 0 else 180)


def patched_board(data, components, index, project_directory):
    """A copy of the board file with library models added to the footprints that lack one."""
    additions = []
    for c in components:
        model = library_model(c, index)
        if model:
            additions.append((c.source_end, model))
    if not additions:
        return None, 0
    additions.sort(key=lambda entry: entry[0], reverse=True)
    out = bytearray(data)
    for end, (path, rotation) in additions:
        if end < len(out) and out[end] == 41:
            escaped = path.replace("\\", "\\\\").replace('"', '\\"')
            text = '(model "%s" (offset (xyz 0 0 0)) (scale (xyz 1 1 1)) (rotate (xyz 0 0 %d)))\n\t' % (escaped, rotation)
            out[end:end] = text.encode()
    # The copy lives outside the project, so project-relative model paths must become absolute.
    project = str(project_directory).replace("\\", "/")
    return bytes(out).replace(b"${KIPRJMOD}", project.encode()), len(additions)


def export_glb(cli, board, variant, source):
    """Exports a board's 3D model with kicad-cli, reusing a cached export while the board file is unchanged."""
    stat = board.stat()
    stamp = "%s|%s|%d|%d" % (variant, board, stat.st_mtime_ns, stat.st_size)
    cache = cache_directory()
    cache.mkdir(parents=True, exist_ok=True)
    output = cache / (hashlib.sha1(stamp.encode()).hexdigest()[:16] + ".glb")
    if output.exists():
        return output
    source_file = source()
    temp = cache / ("export-%d.glb" % os.getpid())
    command = list(cli)
    if command[0] == "flatpak":
        # The sandbox needs to see the board and the folder the export is written to.
        command[2:2] = ["--filesystem=%s" % cache, "--filesystem=%s:ro" % source_file.parent]
    detailed = ["--subst-models", "--include-pads", "--include-silkscreen", "--include-soldermask", "--no-dnp"]
    log = ""
    try:
        # Older KiCad versions lack some of the detail flags, so fall back to a plain export.
        for flags in (detailed, ["--subst-models"]):
            if temp.exists():
                temp.unlink()
            run = subprocess.run(command + ["pcb", "export", "glb"] + flags + ["-f", "-o", str(temp), str(source_file)],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            log = run.stdout.decode("utf-8", "replace")
            if temp.exists() and temp.stat().st_size > 0:
                os.replace(str(temp), str(output))
                return output
    finally:
        if temp.exists():
            temp.unlink()
    raise RuntimeError("kicad-cli could not export the 3D model.\n" + log[-400:])


def load_board(board, fill_models=True, use_kicad=True, say=print):
    """Returns (components, path of the exported 3D file or None, number of borrowed models, warning or None)."""
    data = board.read_bytes()
    components = read_components(data)
    if not components:
        raise RuntimeError("No components with pads were found in %s." % board.name)
    if not use_kicad:
        return components, None, 0, "Showing simplified shapes only (3D export was turned off)."
    cli = locate_kicad_cli()
    if cli is None:
        return components, None, 0, ("Showing simplified shapes only: KiCad's kicad-cli was not found. "
                                     "Install KiCad, or set KICAD_CLI to the path of kicad-cli.")
    patch, count = (None, 0)
    if fill_models:
        patch, count = patched_board(data, components, model_index(model_library_root(cli)), board.parent)

    def source():
        if patch is None:
            return board
        # The private copy sits beside a copy of the project file so project settings still apply.
        work = cache_directory() / "work"
        shutil.rmtree(str(work), ignore_errors=True)
        work.mkdir(parents=True)
        copy = work / board.name
        copy.write_bytes(patch)
        project = board.with_suffix(".kicad_pro")
        if project.exists():
            shutil.copy(str(project), str(work / project.name))
        return copy

    try:
        say("Exporting the 3D board with KiCad (this can take a little while the first time)...")
        glb = export_glb(cli, board, "plain" if patch is None else "filled-1", source)
        return components, glb, count, None
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        return components, None, 0, "Showing simplified shapes only. %s" % error


# ---------------------------------------------------------------------------------------------
# The web page


def resource_directory():
    here = Path(__file__).resolve().parent
    for candidate in (here / "web", here.parent / "Resources" / "web", here):
        if (candidate / "guide.html").exists():
            return candidate
    raise RuntimeError("The web guide template (Resources/web/guide.html) is missing. "
                       "Run this script from a full copy of the pcb-assembly-guide repository.")


def rounded(value):
    return math.copysign(math.floor(abs(value) * 1000 + 0.5) / 1000, value)


def guide_data(name, components, glb, filled, preset="smd-first"):
    groups, steps, group_of_step = assembly_plan(components, preset)
    kit = kit_rows(components)
    quantity = {row["id"]: len(row["refs"]) for row in kit}
    parts = {}
    for c in components:
        cx, cy = c.center
        part = {
            "value": c.value, "fp": c.footprint, "kind": c.kind_name, "dims": c.dimensions, "pads": c.pad_count,
            "bottom": c.is_bottom, "tht": c.is_tht, "x": rounded(cx), "y": rounded(cy), "rot": c.rotation,
            "w": rounded(c.width), "d": rounded(c.depth), "reach": rounded(c.reach), "prefix": c.prefix,
            "qty": quantity.get(c.value + "|" + c.footprint, 1), "nets": c.nets,
        }
        if c.size_label:
            part["size"] = c.size_label
        if c.polarity:
            kind = c.polarity["kind"]
            detail = POLARITY_DETAIL[kind]
            if not c.polarity["confirmed"]:
                detail += " (Assumed from pad 1; check the silkscreen.)"
            part["pol"] = {"label": POLARITY_LABEL[kind], "title": POLARITY_TITLE[kind], "detail": detail,
                           "x": rounded(c.polarity["x"]), "y": rounded(c.polarity["y"])}
        elif c.is_reversible:
            part["rev"] = c.reversible_note
        if c.jumper:
            a, b = c.jumper
            unused = [pad.name for pad in c.pads if pad.name not in (a.name, b.name)]
            pads = []
            for pad in (a, b):
                px, py = c.board_point(pad.x, pad.y)
                pads.append({"x": rounded(px), "y": rounded(py), "hw": pad.half_width, "hh": pad.half_height})
            part["jumper"] = {
                "title": "Bridge pads %s and %s" % (a.name, b.name),
                "detail": "Solder the link across the two pads outlined in blue."
                          + (" Leave pad %s empty." % ", ".join(unused) if unused else ""),
                "pads": pads,
            }
        hint = marking_hint(c)
        if hint:
            part["mark"] = hint
        if c.datasheet and c.datasheet.lower().startswith("http"):
            part["ds"] = c.datasheet
        parts[c.ref] = part
    drawn = sum(1 for c in components if c.has_model) + filled
    return {
        "name": name, "parts": parts, "steps": steps, "gos": group_of_step, "groups": groups, "kit": kit,
        "summary": ("%d of %d parts have a 3D model." % (drawn, len(components)) if glb
                    else "Shown with simplified shapes."),
    }


def write_guide(data, glb, output):
    resources = resource_directory()
    libraries = "\n;\n".join((resources / name).read_text(encoding="utf-8")
                             for name in ("three.min.js", "GLTFLoader.js", "OrbitControls.js"))
    # "</" is escaped so "</script>" can never appear inside the page's data block.
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
    model = base64.b64encode(glb.read_bytes()).decode("ascii") if glb else ""
    title = data["name"].replace("&", "&amp;").replace("<", "&lt;")
    page = (resources / "guide.html").read_text(encoding="utf-8")
    # Each placeholder is filled exactly once, in an order that never rescans inserted content.
    for placeholder, replacement in (("__TITLE__", title), ("/*__LIBS__*/", libraries),
                                     ("__DATA__", payload), ("__GLB__", model)):
        if placeholder not in page:
            raise RuntimeError("The web guide template is damaged.")
        page = page.replace(placeholder, replacement, 1)
    output.write_text(page, encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="pcb_assembly_guide.py",
        description="Write a step-by-step hand-assembly guide for a KiCad board as a single web page.")
    parser.add_argument("board", help="the .kicad_pcb file")
    parser.add_argument("-o", "--output", help="where to write the page (default: <board name>-assembly-guide.html "
                                               "in the current folder)")
    parser.add_argument("--order", choices=sorted(PRESETS), default="smd-first",
                        help="soldering order (default: smd-first, SMD on both sides then through-hole)")
    parser.add_argument("--no-fill", action="store_true",
                        help="do not borrow KiCad library models for chip parts that have no 3D model")
    parser.add_argument("--no-3d", action="store_true", help="skip the KiCad 3D export and draw simple boxes")
    parser.add_argument("--no-open", action="store_true", help="do not open the page in the browser afterwards")
    options = parser.parse_args(argv)

    board = Path(options.board).expanduser().resolve()
    if not board.is_file():
        parser.error("%s does not exist" % board)
    name = board.stem
    output = Path(options.output).expanduser() if options.output else Path.cwd() / (name + "-assembly-guide.html")
    try:
        components, glb, filled, warning = load_board(board, not options.no_fill, not options.no_3d)
        data = guide_data(name, components, glb, filled, options.order)
        write_guide(data, glb, output)
    except (OSError, RuntimeError) as error:
        print("error: %s" % error, file=sys.stderr)
        return 1
    if warning:
        print("note: " + warning)
    print("Wrote %s (%d parts, %d steps, %.1f MB)" % (output, len(components), len(data["steps"]),
                                                      output.stat().st_size / 1e6))
    if not options.no_open:
        webbrowser.open(output.resolve().as_uri())
    return 0


if __name__ == "__main__":
    sys.exit(main())
