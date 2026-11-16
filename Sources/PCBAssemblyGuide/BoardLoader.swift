import Foundation
import SceneKit

struct LoadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Everything needed to guide the assembly of one board.
struct LoadedBoard {
    let url: URL
    let components: [Component]
    /// KiCad's 3D model of the board, or nil if the export was not possible.
    let model: SCNNode?
    /// The exported 3D file the model was read from, kept for the web guide.
    let glb: URL?
    /// How many parts without a model in KiCad were given a standard library model.
    let filledModels: Int
    let warning: String?
}

enum KiCadCLI {
    static func locate() -> URL? {
        let fm = FileManager.default
        var candidates = ["/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"]
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for entry in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where entry.lowercased().hasPrefix("kicad") {
                candidates.append("\(dir)/\(entry)/KiCad.app/Contents/MacOS/kicad-cli")
                candidates.append("\(dir)/\(entry)/Contents/MacOS/kicad-cli")
            }
        }
        candidates += ["/opt/homebrew/bin/kicad-cli", "/usr/local/bin/kicad-cli"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PCBAssemblyGuide", isDirectory: true)
    }

    /// Exports a board's 3D model with kicad-cli, reusing a cached export while the board file is unchanged.
    /// `source` supplies the file to export (the board itself or a patched copy) and is only called on a cache miss.
    static func exportGLB(board: URL, variant: String, source: () throws -> URL) throws -> URL {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: board.path)
        let stamp = "\(variant)|\(board.path)|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attributes[.size] ?? 0)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in stamp.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let output = cacheDirectory.appendingPathComponent(String(hash, radix: 16) + ".glb")
        if fm.fileExists(atPath: output.path) { return output }

        guard let cli = locate() else {
            throw LoadError(message: "KiCad was not found in /Applications, so the 3D model could not be exported.")
        }
        let input = try source()
        let temp = cacheDirectory.appendingPathComponent(UUID().uuidString + ".glb")
        defer { try? fm.removeItem(at: temp) }
        let detailed = ["--subst-models", "--include-pads", "--include-silkscreen", "--include-soldermask", "--no-dnp"]
        var log = ""
        // Older KiCad versions lack some of the detail flags, so fall back to a plain export.
        for flags in [detailed, ["--subst-models"]] {
            try? fm.removeItem(at: temp)
            let process = Process()
            process.executableURL = cli
            process.arguments = ["pcb", "export", "glb"] + flags + ["-f", "-o", temp.path, input.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            if fm.fileExists(atPath: temp.path) {
                try fm.moveItem(at: temp, to: output)
                return output
            }
        }
        throw LoadError(message: "kicad-cli could not export the 3D model.\n" + String(log.suffix(400)))
    }
}

/// Picks standard KiCad library models for parts that have none assigned, so they are not drawn as plain boxes.
/// The user's board file is never changed: the models are added to a private copy that is only used for the export.
enum ModelLibrary {
    static let root: URL? = {
        guard let cli = KiCadCLI.locate() else { return nil }
        let dir = cli.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SharedSupport/3dmodels")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }()

    /// Every STEP model in the library, by lower-cased file name without extension.
    private static let index: [String: String] = {
        guard let root else { return [:] }
        var out: [String: String] = [:]
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where dir.hasSuffix(".3dshapes") {
            for file in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)) ?? []
            where file.lowercased().hasSuffix(".step") {
                out[String(file.dropLast(5)).lowercased()] = root.appendingPathComponent(dir).appendingPathComponent(file).path
            }
        }
        return out
    }()

    private static let metric = [
        "01005": "0402", "0201": "0603", "0402": "1005", "0603": "1608", "0805": "2012",
        "1206": "3216", "1210": "3225", "1812": "4532", "2010": "5025", "2512": "6332",
    ]

    /// The library model for a part and the Z rotation (degrees) that lines it up, or nil when there is no safe match.
    static func model(for c: Component) -> (path: String, rotation: Int)? {
        guard !c.hasModel, c.jumper == nil else { return nil }
        // A footprint named exactly like a library model is the same package.
        if let exact = index[c.footprint.lowercased()] { return (exact, 0) }

        // Otherwise only two-pad chip parts, where the size code alone fixes the shape.
        guard !c.isTHT, c.pads.count == 2, let size = c.chipSize, let mm = metric[size] else { return nil }
        let family: String
        switch c.prefix {
        case "C": family = c.polarity == nil ? "c" : ""
        case "R": family = "r"
        case "L", "FB": family = "l"
        case "D", "LED": family = c.isLED ? "led" : "d"
        default: family = ""
        }
        guard !family.isEmpty, let path = index["\(family)_\(size)_\(mm)metric"] else { return nil }

        // Library models have pad 1 (the cathode on diodes and LEDs) on the −X side.
        let reference = c.polarity.map { ($0.localX, $0.localY) } ?? c.pads.first { $0.name == "1" }.map { ($0.x, $0.y) }
        guard let reference else { return nil }
        let vx = reference.0 - (c.pads[0].x + c.pads[1].x) / 2
        let vy = reference.1 - (c.pads[0].y + c.pads[1].y) / 2
        // Footprints with pads stacked along Y would need a quarter turn, which is left to the plain box.
        guard abs(vx) > abs(vy) else { return nil }
        return (path, vx < 0 ? 0 : 180)
    }

    /// A copy of the board file with library models added to the footprints that lack one.
    static func patchedBoard(_ data: Data, components: [Component], projectDirectory: URL) -> (data: Data, count: Int)? {
        let additions = components.compactMap { c in model(for: c).map { (c.sourceEnd, $0) } }.sorted { $0.0 > $1.0 }
        guard !additions.isEmpty else { return nil }
        var bytes = [UInt8](data)
        for (end, model) in additions where end < bytes.count && bytes[end] == 41 {
            let path = model.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let text = "(model \"\(path)\" (offset (xyz 0 0 0)) (scale (xyz 1 1 1)) (rotate (xyz 0 0 \(model.rotation))))\n\t"
            bytes.insert(contentsOf: Array(text.utf8), at: end)
        }
        // The copy lives outside the project, so project-relative model paths must become absolute.
        let marker = Array("${KIPRJMOD}".utf8)
        var patched = Data(bytes)
        if let text = String(data: patched, encoding: .utf8), bytes.count > marker.count, text.contains("${KIPRJMOD}") {
            patched = Data(text.replacingOccurrences(of: "${KIPRJMOD}", with: projectDirectory.path).utf8)
        }
        return (patched, additions.count)
    }
}

enum BoardLoader {
    static func load(url: URL, fillModels: Bool = true) throws -> LoadedBoard {
        let data = try Data(contentsOf: url)
        let components = KiCadBoard.components(in: data)
        guard !components.isEmpty else {
            throw LoadError(message: "No components with pads were found in \(url.lastPathComponent).")
        }
        let patch = fillModels
            ? ModelLibrary.patchedBoard(data, components: components, projectDirectory: url.deletingLastPathComponent()) : nil

        var model: SCNNode?
        var exported: URL?
        var warning: String?
        do {
            let glb = try KiCadCLI.exportGLB(board: url, variant: patch == nil ? "plain" : "filled-1") {
                guard let patch else { return url }
                // The private copy sits beside a copy of the project file so project settings still apply.
                let fm = FileManager.default
                let work = KiCadCLI.cacheDirectory.appendingPathComponent("work", isDirectory: true)
                try? fm.removeItem(at: work)
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let copy = work.appendingPathComponent(url.lastPathComponent)
                try patch.data.write(to: copy)
                let project = url.deletingPathExtension().appendingPathExtension("kicad_pro")
                try? fm.copyItem(at: project, to: work.appendingPathComponent(project.lastPathComponent))
                return copy
            }
            model = try GLBLoader(url: glb).buildScene()
            exported = glb
        } catch {
            warning = "Showing simplified shapes only. " + error.localizedDescription
        }
        return LoadedBoard(url: url, components: components, model: model, glb: exported,
                           filledModels: model == nil ? 0 : patch?.count ?? 0, warning: warning)
    }
}
