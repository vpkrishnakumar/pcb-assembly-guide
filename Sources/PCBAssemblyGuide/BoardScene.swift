import AppKit
import SceneKit

/// Owns the 3D scene: the board, one node per component, the highlight markers and the camera.
///
/// Scene layout: `flipNode` turns the board over for bottom-side work, `content` holds everything
/// in board millimetres (X = KiCad X, Y = height, Z = KiCad Y) shifted so the board centre is at the origin.
final class BoardSceneController {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    weak var view: SCNView?

    private let flipNode = SCNNode()
    private let content = SCNNode()
    private let ring = SCNNode()
    private let pinDot = SCNNode()
    private let pinLabel = SCNNode()
    private let padMarks = [SCNNode(), SCNNode()]
    private var partNodes: [String: [SCNNode]] = [:]
    private var refOfNode: [ObjectIdentifier: String] = [:]
    private var highlighted: [(node: SCNNode, original: SCNGeometry)] = []
    private var topY: Float = 1.6
    private var bottomY: Float = 0
    private var center = simd_float3(0, 0.8, 0)
    private var boardSpan: Float = 100
    private var flipped = false
    private var flat = false
    private var lastShot: (target: simd_float3, distance: Float)?
    private static let fieldOfView: Float = 35

    init() {
        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(Self.fieldOfView)
        camera.zNear = 1
        camera.zFar = 5000
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        flipNode.addChildNode(content)
        scene.rootNode.addChildNode(flipNode)

        func addLight(intensity: CGFloat, pitch: CGFloat, yaw: CGFloat) {
            let light = SCNLight()
            light.type = .directional
            light.intensity = intensity
            let node = SCNNode()
            node.light = light
            node.eulerAngles = SCNVector3(pitch * .pi / 180, yaw * .pi / 180, 0)
            scene.rootNode.addChildNode(node)
        }
        addLight(intensity: 700, pitch: -55, yaw: 25)
        addLight(intensity: 250, pitch: -40, yaw: -140)
        scene.lightingEnvironment.contents = Self.environmentImage()
        scene.lightingEnvironment.intensity = 1.3
        scene.background.contents = NSColor(white: 0.11, alpha: 1)

        func marker(_ color: NSColor, overlay: Bool) -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color
            material.readsFromDepthBuffer = !overlay
            return material
        }
        let red = NSColor(srgbRed: 1, green: 0.15, blue: 0.15, alpha: 1)

        ring.geometry = SCNTorus(ringRadius: 1, pipeRadius: 0.1)
        ring.geometry?.materials = [marker(NSColor(srgbRed: 0.25, green: 1, blue: 0.45, alpha: 1), overlay: true)]
        ring.renderingOrder = 100
        let pulse = SCNAction.sequence([.scale(to: 1.25, duration: 0.55), .scale(to: 1, duration: 0.55)])
        pulse.timingMode = .easeInEaseOut
        ring.runAction(.repeatForever(pulse))

        pinDot.geometry = SCNSphere(radius: 0.2)
        pinDot.geometry?.materials = [marker(red, overlay: false)]

        // The tag ("K", "+", "1") floats beside the dot and always faces the camera.
        let text = SCNText(string: "1", extrusionDepth: 0)
        text.font = NSFont.systemFont(ofSize: 10, weight: .heavy)
        text.flatness = 0.1
        let labelMaterial = marker(red, overlay: true)
        labelMaterial.isDoubleSided = true
        text.materials = [labelMaterial]
        pinLabel.geometry = text
        pinLabel.constraints = [SCNBillboardConstraint()]
        pinLabel.renderingOrder = 101

        // Outlines of the two pads a jumper link bridges.
        for node in padMarks {
            node.geometry = SCNBox(width: 1, height: 0.06, length: 1, chamferRadius: 0)
            node.geometry?.materials = [marker(NSColor(srgbRed: 0.1, green: 0.85, blue: 1, alpha: 1), overlay: false)]
        }
    }

    /// A soft sky-to-floor gradient so metal pads and leads have something to reflect.
    private static func environmentImage() -> CGImage? {
        let width = 64, height = 32
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: nil, colors: [
                  CGColor(gray: 1, alpha: 1), CGColor(gray: 0.75, alpha: 1), CGColor(gray: 0.3, alpha: 1),
              ] as CFArray, locations: [0, 0.5, 1]) else { return nil }
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
        return ctx.makeImage()
    }

    // MARK: Loading

    func install(_ board: LoadedBoard) {
        content.childNodes.forEach { $0.removeFromParentNode() }
        partNodes = [:]
        refOfNode = [:]
        highlighted = []
        flipped = false
        flipNode.eulerAngles = SCNVector3Zero

        let refs = Set(board.components.map(\.ref))
        var pcbNode: SCNNode?
        func collect(_ node: SCNNode) {
            if let name = node.name, refs.contains(name) {
                partNodes[name, default: []].append(node)
                return
            }
            if node.geometry?.name?.hasSuffix("_PCB") == true { pcbNode = node }
            node.childNodes.forEach(collect)
        }
        if let model = board.model {
            model.simdScale = simd_float3(repeating: 1000)  // glTF is in metres
            content.addChildNode(model)
            collect(model)
        }

        // Extent of the board in the XZ plane, from the board body or else from the parts.
        var lo = simd_float3(repeating: .infinity), hi = simd_float3(repeating: -.infinity)
        if let pcbNode {
            (lo, hi) = bounds(of: pcbNode)
            topY = hi.y
            bottomY = lo.y
        } else {
            topY = 1.6
            bottomY = 0
            for c in board.components {
                let p = c.center, r = Float(c.reach) + 2
                lo = simd_min(lo, simd_float3(Float(p.x) - r, 0, Float(p.y) - r))
                hi = simd_max(hi, simd_float3(Float(p.x) + r, 1.6, Float(p.y) + r))
            }
            let slab = SCNBox(width: CGFloat(hi.x - lo.x), height: 1.6, length: CGFloat(hi.z - lo.z), chamferRadius: 0)
            slab.materials = [Self.plainMaterial(NSColor(srgbRed: 0.05, green: 0.3, blue: 0.15, alpha: 1))]
            let node = SCNNode(geometry: slab)
            node.simdPosition = simd_float3((lo.x + hi.x) / 2, 0.8, (lo.z + hi.z) / 2)
            content.addChildNode(node)
        }

        // KiCad seats models on the copper surface, so prefer where it actually put them.
        func median(_ values: [Float]) -> Float? {
            values.isEmpty ? nil : values.sorted()[values.count / 2]
        }
        func seatHeights(bottom: Bool) -> [Float] {
            board.components.filter { $0.isBottom == bottom }.compactMap { c in
                partNodes[c.ref]?.first.map { Float($0.convertPosition(SCNVector3Zero, to: content).y) }
            }
        }
        topY = median(seatHeights(bottom: false)) ?? topY
        bottomY = median(seatHeights(bottom: true)) ?? bottomY

        for c in board.components where partNodes[c.ref] == nil {
            let node = placeholder(for: c)
            content.addChildNode(node)
            partNodes[c.ref] = [node]
        }
        for (ref, nodes) in partNodes {
            for node in nodes { refOfNode[ObjectIdentifier(node)] = ref }
        }

        center = simd_float3((lo.x + hi.x) / 2, (topY + bottomY) / 2, (lo.z + hi.z) / 2)
        boardSpan = max(hi.x - lo.x, hi.z - lo.z, 10)
        content.simdPosition = -center
        for node in [ring, pinDot, pinLabel] + padMarks {
            content.addChildNode(node)
            node.isHidden = true
        }
        fitBoard(bottom: false, animated: false)
    }

    private static func plainMaterial(_ color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = NSNumber(value: 0)
        material.roughness.contents = NSNumber(value: 0.7)
        return material
    }

    /// A simple box standing in for a part that has no 3D model.
    private func placeholder(for c: Component) -> SCNNode {
        let w = max(c.width, 0.3), d = max(c.depth, 0.3)
        let height = c.isTHT ? min(max(min(w, d), 2), 8) : min(max(min(w, d) * 0.5, 0.3), 2)
        let color: NSColor
        switch c.prefix {
        case "R", "RN": color = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1)
        case "C": color = NSColor(srgbRed: 0.72, green: 0.58, blue: 0.42, alpha: 1)
        case "L", "FB": color = NSColor(srgbRed: 0.4, green: 0.4, blue: 0.42, alpha: 1)
        case "D", "LED": color = NSColor(srgbRed: 0.75, green: 0.3, blue: 0.2, alpha: 1)
        case "U", "IC", "Q": color = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1)
        case "J", "P", "CN": color = NSColor(srgbRed: 0.85, green: 0.82, blue: 0.72, alpha: 1)
        default: color = NSColor(srgbRed: 0.3, green: 0.36, blue: 0.5, alpha: 1)
        }
        let box = SCNBox(width: w, height: height, length: d, chamferRadius: min(0.05, min(w, d) * 0.1))
        box.materials = [Self.plainMaterial(color)]
        let node = SCNNode(geometry: box)
        node.name = c.ref
        let p = c.center
        let y = c.isBottom ? bottomY - Float(height) / 2 : topY + Float(height) / 2
        node.simdPosition = simd_float3(Float(p.x), y, Float(p.y))
        node.eulerAngles.y = c.rotation * .pi / 180
        return node
    }

    /// Bounding box of a node and its children, in board millimetres.
    private func bounds(of node: SCNNode) -> (simd_float3, simd_float3) {
        let (mn, mx) = node.boundingBox
        var lo = simd_float3(repeating: .infinity), hi = simd_float3(repeating: -.infinity)
        for x in [mn.x, mx.x] {
            for y in [mn.y, mx.y] {
                for z in [mn.z, mx.z] {
                    let p = node.convertPosition(SCNVector3(x, y, z), to: content)
                    let v = simd_float3(Float(p.x), Float(p.y), Float(p.z))
                    lo = simd_min(lo, v)
                    hi = simd_max(hi, v)
                }
            }
        }
        return (lo, hi)
    }

    /// The reference of the part drawn at a point in a view, if any.
    func pick(at point: CGPoint, in view: SCNView) -> String? {
        for hit in view.hitTest(point, options: [.searchMode: NSNumber(value: SCNHitTestSearchMode.all.rawValue)]) {
            var node: SCNNode? = hit.node
            while let current = node {
                if let ref = refOfNode[ObjectIdentifier(current)] { return ref }
                node = current.parent
            }
        }
        return nil
    }

    /// Where a part's 3D shape sits, in board millimetres. Used to check models against the board file.
    func modelCenter(of ref: String) -> (x: Float, z: Float)? {
        guard let node = partNodes[ref]?.first else { return nil }
        let (lo, hi) = bounds(of: node)
        return ((lo.x + hi.x) / 2, (lo.z + hi.z) / 2)
    }

    // MARK: Step state

    /// Shows placed parts solid, the current part glowing, `upcoming` parts faint, and hides the rest.
    func apply(placed: Set<String>, current: Component?, upcoming: Set<String>, showAll: Bool) {
        for (ref, nodes) in partNodes {
            let solid = showAll || placed.contains(ref) || ref == current?.ref
            for node in nodes {
                node.isHidden = !(solid || upcoming.contains(ref))
                node.opacity = solid ? 1 : 0.3
            }
        }

        for entry in highlighted { entry.node.geometry = entry.original }
        highlighted = []
        guard let current, let nodes = partNodes[current.ref] else {
            for node in [ring, pinDot, pinLabel] + padMarks { node.isHidden = true }
            return
        }

        // Geometry is shared between identical parts, so the glow goes on a private copy.
        var lo = simd_float3(repeating: .infinity), hi = simd_float3(repeating: -.infinity)
        for node in nodes {
            node.enumerateHierarchy { child, _ in
                guard let geometry = child.geometry, let copy = geometry.copy() as? SCNGeometry else { return }
                copy.materials = geometry.materials.map { original in
                    let material = original.copy() as! SCNMaterial
                    material.emission.contents = NSColor(srgbRed: 1, green: 0.55, blue: 0.05, alpha: 1)
                    material.emission.intensity = 0.55
                    return material
                }
                highlighted.append((child, geometry))
                child.geometry = copy
            }
            let b = bounds(of: node)
            lo = simd_min(lo, b.0)
            hi = simd_max(hi, b.1)
        }

        let side: Float = current.isBottom ? -1 : 1
        let surface = current.isBottom ? bottomY : topY
        let p = current.center
        let radius = CGFloat(current.reach) * 1.2 + 0.5
        if let torus = ring.geometry as? SCNTorus {
            torus.ringRadius = radius
            torus.pipeRadius = max(0.07, radius * 0.035)
        }
        ring.simdPosition = simd_float3(Float(p.x), surface + side * 0.1, Float(p.y))
        ring.isHidden = false

        if let mark = current.polarity, let sphere = pinDot.geometry as? SCNSphere,
           let text = pinLabel.geometry as? SCNText {
            let r = min(max(current.reach * 0.12, 0.15), 0.5)
            sphere.radius = r
            let partTop = current.isBottom ? lo.y : hi.y
            let dot = simd_float3(Float(mark.x), partTop + side * (Float(r) + 0.05), Float(mark.y))
            pinDot.simdPosition = dot
            pinDot.isHidden = false

            text.string = mark.label
            let (mn, mx) = text.boundingBox
            pinLabel.pivot = SCNMatrix4MakeTranslation((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, 0)
            let height = Float(min(max(current.reach * 0.8, 1.5), 3))
            pinLabel.simdScale = simd_float3(repeating: height / 10)
            // Sits just outside the part, on the far side of the dot from the part's centre.
            var outward = simd_float3(Float(mark.x - p.x), 0, Float(mark.y - p.y))
            outward = simd_length(outward) > 0.01 ? simd_normalize(outward) : simd_float3(1, 0, 0)
            pinLabel.simdPosition = dot + outward * (Float(r) + height * 0.8) + simd_float3(0, side * height * 0.4, 0)
            pinLabel.isHidden = false
        } else {
            pinDot.isHidden = true
            pinLabel.isHidden = true
        }

        let bridged = current.jumper.map { [$0.a, $0.b] } ?? []
        for (index, node) in padMarks.enumerated() {
            guard index < bridged.count, let box = node.geometry as? SCNBox else {
                node.isHidden = true
                continue
            }
            let pad = bridged[index]
            box.width = (pad.halfWidth + 0.14) * 2
            box.length = (pad.halfHeight + 0.14) * 2
            let at = current.boardPoint(pad.x, pad.y)
            node.simdPosition = simd_float3(Float(at.x), surface + side * 0.05, Float(at.y))
            node.eulerAngles.y = current.rotation * .pi / 180
            node.isHidden = false
        }
    }

    // MARK: Camera

    func focus(on c: Component, animated: Bool = true) {
        let p = c.center
        let local = simd_float3(Float(p.x), c.isBottom ? bottomY : topY, Float(p.y)) - center
        let target = c.isBottom ? simd_float3(-local.x, -local.y, local.z) : local
        moveCamera(target: target, distance: max(45, Float(c.reach) * 9), bottom: c.isBottom, animated: animated)
    }

    func fitBoard(bottom: Bool? = nil, animated: Bool = true) {
        moveCamera(target: .zero, distance: boardSpan * 1.9, bottom: bottom ?? flipped, animated: animated)
    }

    /// Switches between the tilted 3D view and a flat, straight-down view like the silkscreen drawing.
    func setFlat(_ on: Bool, animated: Bool = true) {
        flat = on
        if let lastShot {
            moveCamera(target: lastShot.target, distance: lastShot.distance, bottom: flipped, animated: animated)
        }
    }

    /// Looks down at `target`, turning the board over when the other side is needed.
    private func moveCamera(target: simd_float3, distance: Float, bottom: Bool, animated: Bool) {
        lastShot = (target, distance)
        let tilt: Float = flat ? 0 : 28 * .pi / 180
        let pov = view?.pointOfView ?? cameraNode
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.45 : 0
        flipped = bottom
        flipNode.eulerAngles = SCNVector3(0, 0, bottom ? CGFloat.pi : 0)
        pov.camera?.usesOrthographicProjection = flat
        pov.camera?.orthographicScale = Double(distance * tan(Self.fieldOfView / 2 * .pi / 180))
        pov.simdPosition = target + simd_float3(0, distance * cos(tilt), distance * sin(tilt))
        pov.simdLook(at: target, up: flat ? simd_float3(0, 0, -1) : simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
        SCNTransaction.commit()
        view?.defaultCameraController.target = SCNVector3(target)
        view?.defaultCameraController.interactionMode = flat ? .pan : .orbitTurntable
    }
}
