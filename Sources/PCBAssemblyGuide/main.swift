import AppKit
import Metal
import SceneKit

// Command-line modes used by the build script and for checking the 3D pipeline without a window:
//   --icon <out.png>                                  draws the app icon
//   --snapshot <board.kicad_pcb> <out.png> [step|all]  renders one step; add --flat, --bottom, --list, --check
//   --export-web <board.kicad_pcb> <out.html>          writes the guide as a single web page
let arguments = CommandLine.arguments

func writePNG(_ image: CGImage, to path: String) throws {
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw LoadError(message: "Could not encode the image.")
    }
    try png.write(to: URL(fileURLWithPath: path))
}

/// A green board with pads, an IC and one highlighted part inside the guide's ring.
func drawIcon() -> CGImage? {
    let size = 1024
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)) }
    func rounded(_ rect: CGRect, _ radius: CGFloat) {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }
    let board = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: board, cornerWidth: 180, cornerHeight: 180, transform: nil))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [
        CGColor(srgbRed: 0.10, green: 0.50, blue: 0.30, alpha: 1), CGColor(srgbRed: 0.03, green: 0.27, blue: 0.17, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    ctx.restoreGState()

    // IC with gold pins.
    fill(0.86, 0.72, 0.36)
    for i in 0..<6 {
        let offset = CGFloat(i) * 44
        rounded(CGRect(x: 236 + offset, y: 700, width: 24, height: 60), 6)
        rounded(CGRect(x: 236 + offset, y: 440, width: 24, height: 60), 6)
    }
    fill(0.11, 0.11, 0.13)
    rounded(CGRect(x: 210, y: 480, width: 300, height: 240), 18)
    fill(0.55, 0.55, 0.58)
    ctx.fillEllipse(in: CGRect(x: 236, y: 672, width: 26, height: 26))

    // Small parts and empty pads.
    for (x, y) in [(600.0, 700.0), (600.0, 600.0), (600.0, 500.0)] {
        fill(0.86, 0.72, 0.36)
        rounded(CGRect(x: x, y: y, width: 40, height: 56), 8)
        rounded(CGRect(x: x + 110, y: y, width: 40, height: 56), 8)
        fill(0.12, 0.12, 0.14)
        rounded(CGRect(x: x + 28, y: y + 4, width: 94, height: 48), 6)
    }
    fill(0.86, 0.72, 0.36)
    for x in [230.0, 340.0] {
        rounded(CGRect(x: x, y: 250, width: 40, height: 56), 8)
        rounded(CGRect(x: x + 60, y: 250, width: 40, height: 56), 8)
    }

    // The part being placed, in the guide's highlight colours.
    rounded(CGRect(x: 590, y: 262, width: 46, height: 70), 8)
    rounded(CGRect(x: 734, y: 262, width: 46, height: 70), 8)
    fill(1.0, 0.56, 0.1)
    rounded(CGRect(x: 622, y: 266, width: 126, height: 62), 8)
    ctx.setStrokeColor(CGColor(srgbRed: 0.25, green: 1, blue: 0.45, alpha: 1))
    ctx.setLineWidth(22)
    ctx.strokeEllipse(in: CGRect(x: 545, y: 157, width: 280, height: 280))
    return ctx.makeImage()
}

do {
    if let flag = arguments.firstIndex(of: "--icon"), arguments.count > flag + 1 {
        guard let icon = drawIcon() else { throw LoadError(message: "Could not draw the icon.") }
        try writePNG(icon, to: arguments[flag + 1])
        exit(0)
    }

    if let flag = arguments.firstIndex(of: "--export-web"), arguments.count >= flag + 3 {
        let board = try BoardLoader.load(url: URL(fileURLWithPath: arguments[flag + 1]),
                                         fillModels: !arguments.contains("--no-fill"))
        let output = URL(fileURLWithPath: arguments[flag + 2])
        try WebExport.write(board: board, plan: AssemblyPlan(components: board.components), to: output)
        print("Wrote \(output.path): \(board.components.count) components; \(board.warning ?? "3D model included")")
        exit(0)
    }

    if let flag = arguments.firstIndex(of: "--snapshot"), arguments.count >= flag + 3 {
        let board = try BoardLoader.load(url: URL(fileURLWithPath: arguments[flag + 1]),
                                         fillModels: !arguments.contains("--no-fill"))
        let plan = AssemblyPlan(components: board.components)
        let controller = BoardSceneController()
        controller.install(board)
        let byRef = Dictionary(uniqueKeysWithValues: board.components.map { ($0.ref, $0) })
        let mode = arguments.count > flag + 3 ? arguments[flag + 3] : "0"
        let step = min(Int(mode) ?? plan.steps.firstIndex(of: mode) ?? 0, plan.steps.count - 1)

        if arguments.contains("--list") {
            for (i, ref) in plan.steps.enumerated() {
                let c = byRef[ref]!
                let mark = c.polarity.map { "\($0.label)\($0.confirmed ? "" : "?")" } ?? (c.isReversible ? "~" : "")
                print(i, ref, c.value, c.sizeLabel ?? "-", c.dimensions, mark,
                      c.jumper.map { "bridge \($0.a.name)-\($0.b.name)" } ?? "", Marking.hint(for: c) ?? "", separator: "\t")
            }
        }
        if arguments.contains("--check") {
            // Every part's 3D shape should sit over its footprint.
            var worst = (ref: "", distance: Float(0))
            for c in board.components {
                guard let at = controller.modelCenter(of: c.ref) else { continue }
                let distance = hypot(at.x - Float(c.center.x), at.z - Float(c.center.y))
                if distance > worst.distance { worst = (c.ref, distance) }
                if distance > 0.6 { print("offset \(c.ref) \(c.footprint): \(distance) mm") }
            }
            print("largest model offset: \(worst.ref) \(worst.distance) mm")
        }

        if mode == "all" {
            controller.apply(placed: [], current: nil, upcoming: [], showAll: true)
            controller.fitBoard(bottom: arguments.contains("--bottom"), animated: false)
        } else {
            let current = byRef[plan.steps[step]]!
            let placed = Set(plan.steps[..<step])
            let group = plan.groups[plan.groupOfStep[step]]
            controller.apply(placed: placed, current: current, upcoming: Set(group.refs).subtracting(placed), showAll: false)
            controller.focus(on: current, animated: false)
            print("step \(step): \(current.ref) \(current.value) \(current.footprint) \(group.stage.title)")
        }
        if arguments.contains("--flat") { controller.setFlat(true, animated: false) }

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = controller.scene
        renderer.pointOfView = controller.cameraNode
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 1400, height: 900), antialiasingMode: .multisampling4X)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw LoadError(message: "Could not render the snapshot.")
        }
        try writePNG(cgImage, to: arguments[flag + 2])
        print("\(board.components.count) components, \(plan.groups.count) groups, \(board.filledModels) standard models added; \(board.warning ?? "3D model loaded")")
        exit(0)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}

GuideApp.main()
