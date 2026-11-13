import AppKit
import Foundation
import SceneKit

struct GLBError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Loads the subset of binary glTF that KiCad writes (triangle meshes, flat colours, node hierarchy)
/// into SceneKit nodes. Node names are preserved; KiCad names each component node by its reference.
final class GLBLoader {
    private let bin: Data
    private let accessors: [[String: Any]]
    private let views: [[String: Any]]
    private let meshes: [[String: Any]]
    private let nodes: [[String: Any]]
    private let materials: [[String: Any]]
    private let sceneRoots: [Int]
    private var materialCache: [Int: SCNMaterial] = [:]
    private var geometryCache: [Int: SCNGeometry] = [:]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        guard data.count >= 20, u32(0) == 0x4654_6C67 else { throw GLBError(message: "Not a GLB file.") }
        var jsonData: Data?
        var binData = Data()
        var offset = 12
        while offset + 8 <= data.count {
            let length = Int(u32(offset))
            let type = u32(offset + 4)
            guard offset + 8 + length <= data.count else { break }
            let body = data.subdata(in: offset + 8 ..< offset + 8 + length)
            if type == 0x4E4F_534A { jsonData = body }
            if type == 0x004E_4942 { binData = body }
            offset += 8 + length
        }
        guard let jsonData, let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw GLBError(message: "GLB file has no scene description.")
        }
        bin = binData
        accessors = json["accessors"] as? [[String: Any]] ?? []
        views = json["bufferViews"] as? [[String: Any]] ?? []
        meshes = json["meshes"] as? [[String: Any]] ?? []
        nodes = json["nodes"] as? [[String: Any]] ?? []
        materials = json["materials"] as? [[String: Any]] ?? []
        let scenes = json["scenes"] as? [[String: Any]] ?? []
        let sceneIndex = json["scene"] as? Int ?? 0
        sceneRoots = sceneIndex < scenes.count ? scenes[sceneIndex]["nodes"] as? [Int] ?? [] : []
    }

    func buildScene() -> SCNNode {
        let root = SCNNode()
        for i in sceneRoots where i < nodes.count { root.addChildNode(buildNode(i)) }
        return root
    }

    private func buildNode(_ index: Int) -> SCNNode {
        let def = nodes[index]
        let node = SCNNode()
        node.name = def["name"] as? String
        if let m = def["matrix"] as? [Double], m.count == 16 {
            let f = m.map(Float.init)
            node.simdTransform = simd_float4x4(columns: (
                simd_float4(f[0], f[1], f[2], f[3]), simd_float4(f[4], f[5], f[6], f[7]),
                simd_float4(f[8], f[9], f[10], f[11]), simd_float4(f[12], f[13], f[14], f[15])))
        } else {
            if let t = def["translation"] as? [Double], t.count == 3 {
                node.simdPosition = simd_float3(Float(t[0]), Float(t[1]), Float(t[2]))
            }
            if let r = def["rotation"] as? [Double], r.count == 4 {
                node.simdOrientation = simd_quatf(ix: Float(r[0]), iy: Float(r[1]), iz: Float(r[2]), r: Float(r[3]))
            }
            if let s = def["scale"] as? [Double], s.count == 3 {
                node.simdScale = simd_float3(Float(s[0]), Float(s[1]), Float(s[2]))
            }
        }
        if let mesh = def["mesh"] as? Int, mesh < meshes.count { node.geometry = geometry(mesh) }
        for child in def["children"] as? [Int] ?? [] where child < nodes.count && child != index {
            node.addChildNode(buildNode(child))
        }
        return node
    }

    // MARK: Accessors

    private struct Layout {
        let offset: Int, stride: Int, count: Int, componentType: Int
    }

    private func layout(_ index: Int, components: Int) -> Layout? {
        guard index >= 0, index < accessors.count else { return nil }
        let a = accessors[index]
        guard let viewIndex = a["bufferView"] as? Int, viewIndex < views.count,
              let count = a["count"] as? Int, let type = a["componentType"] as? Int else { return nil }
        let size: Int
        switch type {
        case 5120, 5121: size = 1
        case 5122, 5123: size = 2
        case 5125, 5126: size = 4
        default: return nil
        }
        let view = views[viewIndex]
        let offset = (view["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
        let declared = view["byteStride"] as? Int ?? 0
        let stride = declared > 0 ? declared : size * components
        guard count > 0, offset + (count - 1) * stride + size * components <= bin.count else { return nil }
        return Layout(offset: offset, stride: stride, count: count, componentType: type)
    }

    private func vec3(_ index: Int) -> [Float]? {
        guard let l = layout(index, components: 3), l.componentType == 5126 else { return nil }
        var out = [Float](repeating: 0, count: l.count * 3)
        bin.withUnsafeBytes { raw in
            for i in 0..<l.count {
                let base = l.offset + i * l.stride
                out[i * 3] = raw.loadUnaligned(fromByteOffset: base, as: Float.self)
                out[i * 3 + 1] = raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self)
                out[i * 3 + 2] = raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self)
            }
        }
        return out
    }

    private func indices(_ index: Int) -> [UInt32]? {
        guard let l = layout(index, components: 1) else { return nil }
        var out = [UInt32](repeating: 0, count: l.count)
        bin.withUnsafeBytes { raw in
            for i in 0..<l.count {
                let base = l.offset + i * l.stride
                switch l.componentType {
                case 5121: out[i] = UInt32(raw.load(fromByteOffset: base, as: UInt8.self))
                case 5123: out[i] = UInt32(raw.loadUnaligned(fromByteOffset: base, as: UInt16.self))
                default: out[i] = raw.loadUnaligned(fromByteOffset: base, as: UInt32.self)
                }
            }
        }
        return out
    }

    // MARK: Geometry

    /// Builds one geometry per mesh, merging its (often thousands of) primitives into one element per material.
    private func geometry(_ meshIndex: Int) -> SCNGeometry? {
        if let cached = geometryCache[meshIndex] { return cached }
        let def = meshes[meshIndex]
        var positions: [Float] = [], normals: [Float] = []
        var materialOrder: [Int] = []
        var indicesByMaterial: [Int: [UInt32]] = [:]

        for prim in def["primitives"] as? [[String: Any]] ?? [] {
            guard (prim["mode"] as? Int ?? 4) == 4,
                  let attributes = prim["attributes"] as? [String: Any],
                  let positionIndex = attributes["POSITION"] as? Int,
                  let p = vec3(positionIndex) else { continue }
            let vertexCount = p.count / 3
            var idx: [UInt32]
            if let i = prim["indices"] as? Int {
                guard let read = indices(i) else { continue }
                idx = read
            } else {
                idx = (0..<UInt32(vertexCount)).map { $0 }
            }
            idx.removeLast(idx.count % 3)
            guard !idx.contains(where: { $0 >= UInt32(vertexCount) }) else { continue }

            var n = (attributes["NORMAL"] as? Int).flatMap(vec3)
            if n?.count != p.count { n = Self.faceNormals(positions: p, indices: idx) }

            let base = UInt32(positions.count / 3)
            positions += p
            normals += n!
            let material = prim["material"] as? Int ?? -1
            if indicesByMaterial[material] == nil { materialOrder.append(material) }
            indicesByMaterial[material, default: []].append(contentsOf: idx.map { $0 + base })
        }
        guard !positions.isEmpty else { return nil }

        let count = positions.count / 3
        func source(_ values: [Float], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            SCNGeometrySource(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: semantic,
                              vectorCount: count, usesFloatComponents: true, componentsPerVector: 3,
                              bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        }
        let elements = materialOrder.map { m -> SCNGeometryElement in
            let idx = indicesByMaterial[m]!
            return SCNGeometryElement(data: idx.withUnsafeBufferPointer { Data(buffer: $0) },
                                      primitiveType: .triangles, primitiveCount: idx.count / 3, bytesPerIndex: 4)
        }
        let geometry = SCNGeometry(sources: [source(positions, .vertex), source(normals, .normal)], elements: elements)
        geometry.materials = materialOrder.map(material)
        geometry.name = def["name"] as? String
        geometryCache[meshIndex] = geometry
        return geometry
    }

    private static func faceNormals(positions p: [Float], indices: [UInt32]) -> [Float] {
        var n = [Float](repeating: 0, count: p.count)
        func point(_ i: Int) -> simd_float3 { simd_float3(p[i * 3], p[i * 3 + 1], p[i * 3 + 2]) }
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let face = simd_cross(point(b) - point(a), point(c) - point(a))
            for v in [a, b, c] {
                n[v * 3] += face.x; n[v * 3 + 1] += face.y; n[v * 3 + 2] += face.z
            }
        }
        for v in 0..<(p.count / 3) {
            let length = (n[v * 3] * n[v * 3] + n[v * 3 + 1] * n[v * 3 + 1] + n[v * 3 + 2] * n[v * 3 + 2]).squareRoot()
            if length > 0 {
                n[v * 3] /= length; n[v * 3 + 1] /= length; n[v * 3 + 2] /= length
            } else {
                n[v * 3 + 1] = 1
            }
        }
        return n
    }

    private func material(_ index: Int) -> SCNMaterial {
        if let cached = materialCache[index] { return cached }
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        var rgba: [CGFloat] = [0.6, 0.6, 0.6, 1]
        var metalness = 0.0, roughness = 0.6
        if index >= 0, index < materials.count {
            let def = materials[index]
            material.name = def["name"] as? String
            material.isDoubleSided = def["doubleSided"] as? Bool ?? false
            let pbr = def["pbrMetallicRoughness"] as? [String: Any] ?? [:]
            if let c = pbr["baseColorFactor"] as? [Double], c.count == 4 { rgba = c.map { CGFloat($0) } }
            metalness = pbr["metallicFactor"] as? Double ?? 1
            roughness = pbr["roughnessFactor"] as? Double ?? 1
        }
        // glTF colours are linear.
        let linear = NSColorSpace(cgColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!) ?? .sRGB
        material.diffuse.contents = NSColor(colorSpace: linear, components: &rgba, count: 4)
        material.metalness.contents = NSNumber(value: metalness)
        material.roughness.contents = NSNumber(value: max(roughness, 0.25))
        if rgba[3] < 0.999 {
            material.transparency = rgba[3]
            material.blendMode = .alpha
        }
        materialCache[index] = material
        return material
    }
}
