import Foundation

/// Writes the guide as one self-contained HTML file: the 3D board, the plan and the part details,
/// with the viewer code inlined. It opens in any browser, with nothing to install.
enum WebExport {
    /// The page template and the 3D library, shipped in the app bundle (or beside the sources in a dev build).
    private static func resourceDirectory() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("web")) }
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            candidates.append(directory.appendingPathComponent("Resources/web"))
            directory = directory.deletingLastPathComponent()
        }
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("guide.html").path) }
    }

    static func write(board: LoadedBoard, plan: AssemblyPlan, to output: URL) throws {
        guard let resources = resourceDirectory() else {
            throw LoadError(message: "The web guide template is missing from this copy of the app.")
        }
        func text(_ name: String) throws -> String {
            try String(contentsOf: resources.appendingPathComponent(name), encoding: .utf8)
        }
        let libraries = try ["three.min.js", "GLTFLoader.js", "OrbitControls.js"].map(text).joined(separator: "\n;\n")
        let name = board.url.deletingPathExtension().lastPathComponent

        let kit = KitRow.rows(for: board.components)
        let quantity = Dictionary(uniqueKeysWithValues: kit.map { ($0.id, $0.refs.count) })
        func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

        var parts: [String: Any] = [:]
        for c in board.components {
            let center = c.center
            var part: [String: Any] = [
                "value": c.value, "fp": c.footprint, "kind": c.kindName, "dims": c.dimensions, "pads": c.padCount,
                "bottom": c.isBottom, "tht": c.isTHT, "x": rounded(center.x), "y": rounded(center.y),
                "rot": c.rotation, "w": rounded(c.width), "d": rounded(c.depth), "reach": rounded(c.reach),
                "prefix": c.prefix, "qty": quantity[c.value + "|" + c.footprint] ?? 1,
                "nets": c.nets.map { [$0.pad, $0.net] },
            ]
            if let size = c.sizeLabel { part["size"] = size }
            if let polarity = c.polarity {
                part["pol"] = ["label": polarity.label, "title": polarity.title, "detail": polarity.detail,
                               "x": rounded(polarity.x), "y": rounded(polarity.y)]
            } else if c.isReversible {
                part["rev"] = c.reversibleNote
            }
            if let jumper = c.jumper {
                let unused = c.pads.map(\.name).filter { $0 != jumper.a.name && $0 != jumper.b.name }
                part["jumper"] = [
                    "title": "Bridge pads \(jumper.a.name) and \(jumper.b.name)",
                    "detail": "Solder the link across the two pads outlined in blue."
                        + (unused.isEmpty ? "" : " Leave pad \(unused.joined(separator: ", ")) empty."),
                    "pads": [jumper.a, jumper.b].map { pad -> [String: Any] in
                        let at = c.boardPoint(pad.x, pad.y)
                        return ["x": rounded(at.x), "y": rounded(at.y), "hw": pad.halfWidth, "hh": pad.halfHeight]
                    },
                ]
            }
            if let hint = Marking.hint(for: c) { part["mark"] = hint }
            if let datasheet = c.datasheet, datasheet.lowercased().hasPrefix("http") { part["ds"] = datasheet }
            parts[c.ref] = part
        }

        let drawn = board.components.filter(\.hasModel).count + board.filledModels
        let data: [String: Any] = [
            "name": name,
            "parts": parts,
            "steps": plan.steps,
            "gos": plan.groupOfStep,
            "groups": plan.groups.map { group -> [String: Any] in
                var entry: [String: Any] = ["stage": group.stage.title, "value": group.value, "fp": group.footprint,
                                            "refs": group.refs]
                if let size = group.sizeLabel { entry["size"] = size }
                return entry
            },
            "kit": kit.map { row -> [String: Any] in
                var entry: [String: Any] = ["id": row.id, "kind": row.kind, "value": row.value, "fp": row.footprint,
                                            "refs": row.refs]
                if let size = row.sizeLabel { entry["size"] = size }
                return entry
            },
            "summary": board.glb == nil ? "Shown with simplified shapes."
                : "\(drawn) of \(board.components.count) parts have a 3D model.",
        ]
        // JSONSerialization escapes "/" so "</script>" can never appear inside the page's data block.
        let json = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
        let model = try board.glb.map { try Data(contentsOf: $0).base64EncodedString() } ?? ""
        let title = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")

        // Each placeholder is filled exactly once, in an order that never rescans inserted content.
        var page = try text("guide.html")
        for (placeholder, replacement) in [("__TITLE__", title), ("/*__LIBS__*/", libraries), ("__DATA__", json), ("__GLB__", model)] {
            guard let range = page.range(of: placeholder) else {
                throw LoadError(message: "The web guide template is damaged.")
            }
            page.replaceSubrange(range, with: replacement)
        }
        try Data(page.utf8).write(to: output, options: .atomic)
    }
}
