import Foundation

/// One pad of a footprint, in the footprint's own (unrotated) frame.
struct Pad {
    let name: String
    let x: Double
    let y: Double
    /// Half extents along the footprint's X and Y axes.
    let halfWidth: Double
    let halfHeight: Double
    let net: String
    /// Schematic pin name, upper-cased ("K", "A", "+", "VDD").
    let function: String
}

/// One footprint that has to be soldered onto the board.
/// Board coordinates are KiCad's: millimetres, X right, Y down, as seen from the top.
struct Component: Identifiable {
    let ref: String
    let value: String
    let footprint: String
    let isBottom: Bool
    let x: Double
    let y: Double
    let rotation: Double
    let isTHT: Bool
    let padCount: Int
    let pads: [Pad]
    /// Body outline in the footprint's own (unrotated) frame.
    let minX: Double, minY: Double, maxX: Double, maxY: Double
    /// Radius around the body centre that encloses body and pads.
    let reach: Double
    /// Which way round the part goes, or nil when it does not matter or cannot be told.
    let polarity: Polarity?
    /// For a 0 Ω link on a multi-pad jumper footprint: the two pads it bridges.
    let jumper: (a: Pad, b: Pad)?
    let datasheet: String?
    let partNumber: String?
    /// Whether the footprint has a 3D model assigned in KiCad.
    let hasModel: Bool
    /// Byte offset of the footprint's closing parenthesis in the board file.
    let sourceEnd: Int

    var id: String { ref }
    var width: Double { maxX - minX }
    var depth: Double { maxY - minY }
    var area: Double { width * depth }
    var prefix: String { String(ref.prefix { $0.isLetter }).uppercased() }
    var isIC: Bool { prefix == "U" || prefix == "IC" }
    var isLED: Bool {
        prefix == "LED" || footprint.uppercased().contains("LED") || value.uppercased().contains("LED")
    }

    /// Converts a point in the footprint frame to board coordinates.
    func boardPoint(_ lx: Double, _ ly: Double) -> (x: Double, y: Double) {
        let a = rotation * .pi / 180
        return (x + lx * cos(a) + ly * sin(a), y - lx * sin(a) + ly * cos(a))
    }

    var center: (x: Double, y: Double) {
        boardPoint((minX + maxX) / 2, (minY + maxY) / 2)
    }

    /// Two-pad parts with no polarity can go either way round.
    var isReversible: Bool { polarity == nil && padCount == 2 }

    var reversibleNote: String {
        Self.isBidirectionalTVS(value) ? "Bidirectional TVS: fits either way round" : "Not polarised: fits either way round"
    }

    /// TVS part numbers such as SMBJ6.0CA: the "CA" suffix means bidirectional, so orientation is free.
    static func isBidirectionalTVS(_ value: String) -> Bool {
        value.range(of: #"^(SM[A-D]J|SMF|P[46]KE|1\.5KE)[0-9.]+CA"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    var kindName: String {
        switch prefix {
        case "R": return jumper == nil ? "Resistor" : "Jumper link"
        case "RN": return "Resistor array"
        case "C": return "Capacitor"
        case "L": return "Inductor"
        case "FB": return "Ferrite bead"
        case "D": return isLED ? "LED" : "Diode"
        case "LED": return "LED"
        case "U", "IC": return "IC"
        case "Q": return "Transistor"
        case "J", "P", "CN": return "Connector"
        case "Y", "X": return "Crystal"
        case "SW", "S": return "Switch"
        case "F": return "Fuse"
        default: return "Part"
        }
    }

    /// Imperial chip size code in the footprint name, e.g. "0402".
    var chipSize: String? {
        let pattern = #"(?<![0-9])(01005|0201|0402|0603|0805|1206|1210|1806|1812|2010|2512)(?![0-9])"#
        return footprint.range(of: pattern, options: .regularExpression).map { String(footprint[$0]) }
    }

    /// The package size to look for on the reel or bag, e.g. "0402" or "SOT-23-5".
    var sizeLabel: String? {
        if let chipSize { return chipSize }
        let pattern = #"(?i)(SOT-?[0-9]+(-[0-9]+)?|SOD-?[0-9]+[A-Z]*|SOIC-?[0-9]+|T?SSOP-?[0-9]+|MSOP-?[0-9]+|SOP-?[0-9]+(?![0-9P])|[LT]?QFP-?[0-9]+|[A-Z]?QFN-?[0-9]+|DFN-?[0-9]+|WSON(-[0-9]+)?(?!x)|BGA-?[0-9]+|TO-?[0-9]+|DO-?[0-9]+[A-Z]*|SM[ABC](?![A-Z]))"#
        return footprint.range(of: pattern, options: .regularExpression).map { String(footprint[$0]) }
    }

    var dimensions: String {
        String(format: "%.1f × %.1f mm", max(width, depth), min(width, depth))
    }

    /// Pad-to-net connections, one entry per pad name.
    var nets: [(pad: String, net: String)] {
        var seen = Set<String>()
        return pads.filter { !$0.net.isEmpty && seen.insert($0.name).inserted }.map { ($0.name, $0.net) }
    }
}

/// The pad that fixes a part's orientation, and how to recognise it on the real part.
struct Polarity {
    enum Kind {
        case diode, led, positive, pin1, connector
    }

    let kind: Kind
    /// The marked pad, in board coordinates.
    let x: Double
    let y: Double
    /// The marked pad, in the footprint frame.
    let localX: Double
    let localY: Double
    let padName: String
    /// False when the schematic's pin names did not say, and KiCad's pad-1 convention was used instead.
    let confirmed: Bool

    /// Short tag drawn next to the marker in the 3D view.
    var label: String {
        switch kind {
        case .diode, .led: return "K"
        case .positive: return "+"
        case .pin1, .connector: return "1"
        }
    }

    var title: String {
        switch kind {
        case .diode, .led: return "Polarised: cathode (K) at the red dot"
        case .positive: return "Polarised: positive (+) at the red dot"
        case .pin1, .connector: return "Pin 1 at the red dot"
        }
    }

    var detail: String {
        let text: String
        switch kind {
        case .diode:
            text = "The cathode end of the part has a line or band. Put the band towards the red dot."
        case .led:
            text = "The cathode is marked by a green dot or line on top, or by the bar of the T / point of the arrow underneath. If unsure, use a multimeter in diode mode: the LED lights with the black probe on the cathode."
        case .positive:
            text = "Tantalum: the stripe is +, so it goes at the red dot. Aluminium can: the stripe is −, so it goes away from the red dot."
        case .pin1:
            text = "Find the dot, dimple or notch on the package and put that corner at the red dot."
        case .connector:
            text = "Turn the housing to match the 3D view. Pin 1 is at the red dot."
        }
        return confirmed ? text : text + " (Assumed from pad 1; check the silkscreen.)"
    }
}

enum KiCadBoard {
    /// Reads every assembled footprint from the contents of a `.kicad_pcb` file.
    static func components(in data: Data) -> [Component] {
        var scanner = SExprScanner(data)
        let footprints = scanner.topLevelLists(named: ["footprint", "module"])
        var seen = Set<String>()
        return footprints.compactMap { component(from: $0.expr, end: $0.end) }.filter { seen.insert($0.ref).inserted }
    }

    private struct Box {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var isValid: Bool { minX <= maxX && minY <= maxY }
        mutating func add(_ x: Double, _ y: Double) {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        mutating func add(_ n: [Double]?) {
            if let n, n.count >= 2 { add(n[0], n[1]) }
        }
    }

    private static func component(from fp: SExpr, end: Int) -> Component? {
        let items = fp.items
        guard items.count > 2 else { return nil }
        let libID = items[1].string ?? ""
        let footprint = libID.split(separator: ":").last.map(String.init) ?? libID

        var ref = "", value = "", layer = "F.Cu"
        var x = 0.0, y = 0.0, rot = 0.0
        var attrs = Set<String>()
        var dnp = false, hasModel = false
        var fab = Box(), padBox = Box()
        var thruCount = 0
        var pads: [Pad] = []
        var properties: [String: String] = [:]

        func onFab(_ item: SExpr) -> Bool {
            item.child("layer")?.args.first?.hasSuffix(".Fab") ?? false
        }

        for item in items.dropFirst(2) {
            switch item.head {
            case "layer":
                layer = item.args.first ?? layer
            case "at":
                let n = item.numbers
                if n.count >= 2 { x = n[0]; y = n[1] }
                rot = n.count >= 3 ? n[2] : 0
            case "property":
                let a = item.items
                if a.count >= 3, let key = a[1].string, let val = a[2].string {
                    if key == "Reference" { ref = val }
                    if key == "Value" { value = val }
                    properties[key.uppercased()] = val
                }
            case "fp_text":
                let a = item.items
                if a.count >= 3, let kind = a[1].string, let val = a[2].string {
                    if kind == "reference" { ref = val }
                    if kind == "value" { value = val }
                }
            case "attr":
                attrs = Set(item.args)
            case "dnp":
                dnp = item.args.first != "no"
            case "model":
                hasModel = true
            case "pad":
                let a = item.items
                guard a.count >= 3, let type = a[2].string, type != "np_thru_hole",
                      let at = item.child("at")?.numbers, at.count >= 2,
                      let size = item.child("size")?.numbers, size.count >= 2 else { continue }
                // A pad's stored angle includes the footprint's rotation.
                let t = ((at.count >= 3 ? at[2] : 0) - rot) * .pi / 180
                let hw = (abs(size[0] * cos(t)) + abs(size[1] * sin(t))) / 2
                let hh = (abs(size[0] * sin(t)) + abs(size[1] * cos(t))) / 2
                padBox.add(at[0] - hw, at[1] - hh)
                padBox.add(at[0] + hw, at[1] + hh)
                if type == "thru_hole" { thruCount += 1 }
                let name = a[1].string ?? ""
                guard !name.isEmpty else { continue }
                // KiCad stores the schematic pin name as "<name>_<pad number>".
                var function = item.child("pinfunction")?.args.first ?? ""
                if function.hasSuffix("_" + name) { function.removeLast(name.count + 1) }
                pads.append(Pad(name: name, x: at[0], y: at[1], halfWidth: hw, halfHeight: hh,
                                net: item.child("net")?.args.last ?? "", function: function.uppercased()))
            case "fp_line", "fp_rect":
                if onFab(item) {
                    fab.add(item.child("start")?.numbers)
                    fab.add(item.child("end")?.numbers)
                }
            case "fp_circle":
                if onFab(item), let c = item.child("center")?.numbers, c.count >= 2,
                   let e = item.child("end")?.numbers, e.count >= 2 {
                    let r = hypot(e[0] - c[0], e[1] - c[1])
                    fab.add(c[0] - r, c[1] - r)
                    fab.add(c[0] + r, c[1] + r)
                }
            case "fp_poly":
                if onFab(item) {
                    for p in item.child("pts")?.children("xy") ?? [] { fab.add(p.numbers) }
                }
            default:
                break
            }
        }

        // Skip things that are not soldered parts: logos, fiducials, mounting holes, DNP.
        guard !ref.isEmpty, !ref.hasPrefix("#"), !ref.contains("*"), !pads.isEmpty else { return nil }
        if dnp || attrs.contains("dnp") || attrs.contains("board_only") || attrs.contains("exclude_from_bom") {
            return nil
        }

        var body = fab
        if !body.isValid || body.maxX - body.minX < 0.05 || body.maxY - body.minY < 0.05 { body = padBox }
        if !body.isValid { body = Box(minX: -0.5, minY: -0.5, maxX: 0.5, maxY: 0.5) }

        // Some footprints draw the outline around the leads as well as the body. Where the outline reaches
        // past the centre of outward-pointing pads, the body really stops at their inner ends.
        if pads.count > 4 {
            var trimmed = body
            if let p = pads.max(by: { $0.x < $1.x }), p.halfWidth > p.halfHeight * 1.2, body.maxX > p.x { trimmed.maxX = p.x - p.halfWidth }
            if let p = pads.min(by: { $0.x < $1.x }), p.halfWidth > p.halfHeight * 1.2, body.minX < p.x { trimmed.minX = p.x + p.halfWidth }
            if let p = pads.max(by: { $0.y < $1.y }), p.halfHeight > p.halfWidth * 1.2, body.maxY > p.y { trimmed.maxY = p.y - p.halfHeight }
            if let p = pads.min(by: { $0.y < $1.y }), p.halfHeight > p.halfWidth * 1.2, body.minY < p.y { trimmed.minY = p.y + p.halfHeight }
            if trimmed.maxX - trimmed.minX > (body.maxX - body.minX) * 0.4,
               trimmed.maxY - trimmed.minY > (body.maxY - body.minY) * 0.4 {
                body = trimmed
            }
        }

        // A link on a jumper footprint only covers the two pads named in its value, e.g. "0R (pads 2-3)".
        var jumper: (a: Pad, b: Pad)?
        var reachBox = padBox
        if let range = value.range(of: #"(?i)pads?\s*[A-Za-z0-9]+\s*-\s*[A-Za-z0-9]+"#, options: .regularExpression) {
            let names = value[range]
                .replacingOccurrences(of: #"(?i)pads?\s*"#, with: "", options: .regularExpression)
                .split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            if names.count == 2, names[0] != names[1],
               let a = pads.first(where: { $0.name == names[0] }), let b = pads.first(where: { $0.name == names[1] }) {
                jumper = (a, b)
                body = Box()
                body.add(min(a.x, b.x) - 0.25, min(a.y, b.y) - 0.25)
                body.add(max(a.x, b.x) + 0.25, max(a.y, b.y) + 0.25)
                reachBox = Box()
                for p in [a, b] {
                    reachBox.add(p.x - p.halfWidth, p.y - p.halfHeight)
                    reachBox.add(p.x + p.halfWidth, p.y + p.halfHeight)
                }
            }
        }

        let cx = (body.minX + body.maxX) / 2, cy = (body.minY + body.maxY) / 2
        var reach = hypot(body.maxX - body.minX, body.maxY - body.minY) / 2
        if reachBox.isValid {
            for (px, py) in [(reachBox.minX, reachBox.minY), (reachBox.minX, reachBox.maxY),
                             (reachBox.maxX, reachBox.minY), (reachBox.maxX, reachBox.maxY)] {
                reach = max(reach, hypot(px - cx, py - cy))
            }
        }

        let prefix = String(ref.prefix { $0.isLetter }).uppercased()
        let mark = jumper == nil ? polarityMark(prefix: prefix, footprint: footprint, value: value, pads: pads) : nil
        let a = rot * .pi / 180
        let polarity = mark.map {
            Polarity(kind: $0.kind, x: x + $0.pad.x * cos(a) + $0.pad.y * sin(a),
                     y: y - $0.pad.x * sin(a) + $0.pad.y * cos(a),
                     localX: $0.pad.x, localY: $0.pad.y, padName: $0.pad.name, confirmed: $0.confirmed)
        }

        func property(_ keys: [String]) -> String? {
            keys.lazy.compactMap { properties[$0] }.first { !$0.isEmpty && $0 != "~" }
        }

        return Component(
            ref: ref, value: value, footprint: footprint,
            isBottom: layer.hasPrefix("B."),
            x: x, y: y, rotation: rot,
            isTHT: attrs.contains("through_hole") || (!attrs.contains("smd") && thruCount > 0 && thruCount * 2 >= pads.count),
            padCount: pads.count, pads: pads,
            minX: body.minX, minY: body.minY, maxX: body.maxX, maxY: body.maxY,
            reach: reach, polarity: polarity, jumper: jumper,
            datasheet: property(["DATASHEET"]),
            partNumber: property(["MPN", "MP", "MANUFACTURER PART NUMBER", "MANUFACTURER_PART_NUMBER", "SNAPEDA_PN", "LCSC"]),
            hasModel: hasModel, sourceEnd: end
        )
    }

    /// Works out which pad fixes the orientation.
    private static func polarityMark(
        prefix: String, footprint: String, value: String, pads: [Pad]
    ) -> (kind: Polarity.Kind, pad: Pad, confirmed: Bool)? {
        let padNames = Set(pads.map(\.name))
        let first = pads.first { $0.name == "1" || $0.name == "A1" }
        let isLED = prefix == "LED" || footprint.uppercased().contains("LED") || value.uppercased().contains("LED")

        if padNames.count == 2 {
            if Component.isBidirectionalTVS(value) { return nil }
            // Schematic pin names are the reliable source for two-terminal parts.
            if let k = pads.first(where: { ["K", "CATHODE", "KATHODE", "CATH"].contains($0.function) }) {
                return (isLED ? .led : .diode, k, true)
            }
            if let plus = pads.first(where: { ["+", "POS", "P+"].contains($0.function) }) {
                return (.positive, plus, true)
            }
            if let minus = pads.first(where: { ["-", "NEG"].contains($0.function) }),
               let plus = pads.first(where: { $0.name != minus.name }) {
                return (.positive, plus, true)
            }
            guard let first else { return nil }
            if prefix == "D" || prefix == "LED" { return (isLED ? .led : .diode, first, false) }
            let f = footprint.lowercased()
            if prefix == "C", footprint.hasPrefix("CP_") || f.contains("elec") || f.contains("tant") {
                return (.positive, first, false)
            }
            return nil
        }

        guard let first, padNames.count > 2 else { return nil }
        switch prefix {
        case "R", "C", "L", "FB", "F", "RN", "RV", "TP", "JP", "H", "MH", "SW", "S":
            return nil
        case "J", "P", "CN":
            return (.connector, first, true)
        default:
            return (.pin1, first, true)
        }
    }
}
