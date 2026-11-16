"""Tests for the command-line tool. Run with:  python3 -m unittest discover -s tests"""
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "cli"))
import pcb_assembly_guide as guide  # noqa: E402

BOARD = ROOT / "tests" / "fixtures" / "sample.kicad_pcb"


class BoardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.components = guide.read_components(BOARD.read_bytes())
        cls.by_ref = {c.ref: c for c in cls.components}
        cls.data = guide.guide_data("sample", cls.components, None, 0)

    def test_only_soldered_parts_are_listed(self):
        # R9 is "do not populate" and H1 has no solderable pads.
        self.assertEqual(sorted(self.by_ref), ["C1", "D1", "J1", "R1", "R2", "R3", "U1"])

    def test_sides_and_mounting(self):
        self.assertTrue(self.by_ref["C1"].is_bottom)
        self.assertFalse(self.by_ref["R1"].is_bottom)
        self.assertTrue(self.by_ref["J1"].is_tht)
        self.assertFalse(self.by_ref["U1"].is_tht)

    def test_led_cathode_comes_from_the_schematic_pin_name(self):
        pol = self.data["parts"]["D1"]["pol"]
        self.assertEqual(pol["label"], "K")
        # D1 is turned 180 degrees, so pad 1 (x = -0.7875 in the footprint) ends up to the right.
        self.assertAlmostEqual(pol["x"], 120.788, places=3)
        self.assertAlmostEqual(pol["y"], 100.0, places=3)

    def test_ic_gets_pin_one(self):
        pol = self.data["parts"]["U1"]["pol"]
        self.assertEqual(pol["title"], "Pin 1 at the red dot")
        self.assertAlmostEqual(pol["x"], 105 - 2.475, places=3)
        self.assertAlmostEqual(pol["y"], 110 - 1.905, places=3)

    def test_plain_resistor_is_reversible(self):
        part = self.data["parts"]["R1"]
        self.assertNotIn("pol", part)
        self.assertEqual(part["rev"], "Not polarised: fits either way round")

    def test_sizes_and_kinds(self):
        parts = self.data["parts"]
        self.assertEqual(parts["R1"]["size"], "0603")
        self.assertEqual(parts["U1"]["size"], "SOIC-8")
        self.assertEqual(parts["D1"]["kind"], "LED")
        self.assertEqual(parts["R3"]["kind"], "Jumper link")
        self.assertEqual(parts["R1"]["dims"], "1.6 × 0.8 mm")

    def test_jumper_link_names_its_two_pads(self):
        jumper = self.data["parts"]["R3"]["jumper"]
        self.assertEqual(jumper["title"], "Bridge pads 2 and 3")
        self.assertIn("Leave pad 1 empty", jumper["detail"])
        self.assertEqual([round(p["x"], 3) for p in jumper["pads"]], [115.0, 116.0])

    def test_order_is_ics_first_then_small_to_large_then_other_side_then_through_hole(self):
        steps = self.data["steps"]
        self.assertEqual(steps[0], "U1")
        self.assertEqual(steps[-1], "J1")
        self.assertLess(steps.index("R1"), steps.index("C1"))
        self.assertEqual(abs(steps.index("R1") - steps.index("R2")), 1)
        self.assertEqual(len(steps), len(self.data["gos"]))

    def test_kit_counts(self):
        row = next(r for r in self.data["kit"] if r["value"] == "10k")
        self.assertEqual(row["refs"], ["R1", "R2"])
        self.assertEqual(self.data["parts"]["R1"]["qty"], 2)

    def test_datasheet_links_only_when_they_are_urls(self):
        self.assertEqual(self.data["parts"]["D1"]["ds"], "https://example.com/led.pdf")
        self.assertNotIn("ds", self.data["parts"]["R1"])


class MarkingTests(unittest.TestCase):
    def test_ohms(self):
        cases = {"10k": 10000, "4k7": 4700, "100R": 100, "2.2M": 2.2e6, "0R (pads 1-2)": 0, "470": 470, "R47": 0.47}
        for text, expected in cases.items():
            self.assertAlmostEqual(guide.ohms(text), expected, msg=text)
        self.assertIsNone(guide.ohms("10kR"))
        self.assertIsNone(guide.ohms("DNP"))

    def test_eia_codes(self):
        self.assertEqual(guide.eia_code(10000, 2), "103")
        self.assertEqual(guide.eia_code(10000, 3), "1002")
        self.assertEqual(guide.eia_code(470, 2), "471")
        self.assertEqual(guide.eia_code(4.7, 2), "4R7")

    def test_numeric_compare(self):
        self.assertLess(guide.numeric_compare("R2", "R10"), 0)
        self.assertEqual(guide.numeric_compare("C5", "C5"), 0)


class PageTests(unittest.TestCase):
    def test_page_is_complete_and_self_contained(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "guide.html"
            code = guide.main([str(BOARD), "-o", str(output), "--no-3d", "--no-open"])
            self.assertEqual(code, 0)
            page = output.read_text(encoding="utf-8")
        for placeholder in ("__TITLE__", "__DATA__", "__GLB__", "/*__LIBS__*/"):
            self.assertNotIn(placeholder, page)
        self.assertIn("<title>sample", page)
        self.assertNotRegex(page, r'<script[^>]+src=')  # nothing is loaded from the network
        data = json.loads(re.search(r'<script type="application/json" id="data">(.*?)</script>', page, re.S).group(1))
        self.assertEqual(len(data["steps"]), 7)


if __name__ == "__main__":
    unittest.main()
