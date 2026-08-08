import SwiftUI
import SceneKit
import simd
import CTModels

/// The right-hand viewport: a live SceneKit preview of the selected
/// Model/Skin record's decoded geometry, with orbit/zoom/pan built in via
/// `SCNView`'s default camera controller.
struct ViewportPanel: View {
    let node: ChunkNode?

    var body: some View {
        Group {
            if let mesh = meshPayload {
                SceneKitMeshView(mesh: mesh)
                    .id(node?.id) // rebuild the scene when the selection changes
            } else {
                ContentUnavailableView(
                    "No 3D Preview",
                    systemImage: "cube.transparent",
                    description: Text("Select a Model or Skin record to preview its geometry here.")
                )
            }
        }
        .frame(minWidth: 320)
    }

    private var meshPayload: MeshAsset? {
        if case .mesh(let mesh) = node?.payload { return mesh }
        return nil
    }
}

struct SceneKitMeshView: NSViewRepresentable {
    let mesh: MeshAsset

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = NSColor.controlBackgroundColor
        view.scene = MeshSceneBuilder.buildScene(for: mesh)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        nsView.scene = MeshSceneBuilder.buildScene(for: mesh)
    }
}

enum MeshSceneBuilder {
    static func buildScene(for mesh: MeshAsset) -> SCNScene {
        let scene = SCNScene()
        let root = SCNNode()

        var minBound = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for submesh in mesh.submeshes {
            guard !submesh.vertices.isEmpty else { continue }
            let node = SCNNode(geometry: geometry(for: submesh))
            root.addChildNode(node)
            for v in submesh.vertices {
                minBound = simd_min(minBound, v.position)
                maxBound = simd_max(maxBound, v.position)
            }
        }
        scene.rootNode.addChildNode(root)

        let center = (minBound + maxBound) / 2
        let extent = maxBound - minBound
        let radius = max(extent.x, max(extent.y, extent.z), 1)
        root.position = SCNVector3(-center.x, -center.y, -center.z)

        let camera = SCNCamera()
        camera.zFar = Double(radius) * 20
        camera.zNear = 0.01
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, radius * 0.6, radius * 1.8)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        return scene
    }

    private static func geometry(for submesh: MeshSubmesh) -> SCNGeometry {
        let vertexCount = submesh.vertices.count

        var positions = [SCNVector3](); positions.reserveCapacity(vertexCount)
        var normals = [SCNVector3](); normals.reserveCapacity(vertexCount)
        var uvs = [CGPoint](); uvs.reserveCapacity(vertexCount)
        var colors = [SCNVector4](); colors.reserveCapacity(vertexCount)

        for v in submesh.vertices {
            positions.append(SCNVector3(v.position.x, v.position.y, v.position.z))
            normals.append(SCNVector3(v.normal.x, v.normal.y, v.normal.z))
            uvs.append(CGPoint(x: CGFloat(v.uv.x), y: CGFloat(v.uv.y)))
            colors.append(SCNVector4(Float(v.color.x) / 255.0, Float(v.color.y) / 255.0, Float(v.color.z) / 255.0, Float(v.color.w) / 255.0))
        }

        let positionSource = SCNGeometrySource(vertices: positions)
        let normalSource = SCNGeometrySource(normals: normals)
        let uvSource = SCNGeometrySource(textureCoordinates: uvs)
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<SCNVector4>.stride)
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SCNVector4>.stride
        )

        let triangles = submesh.triangleIndices()
        var indices: [Int32] = []
        indices.reserveCapacity(triangles.count * 3)
        for (a, b, c) in triangles {
            guard a < vertexCount, b < vertexCount, c < vertexCount else { continue }
            indices.append(Int32(a)); indices.append(Int32(b)); indices.append(Int32(c))
        }
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geometry = SCNGeometry(sources: [positionSource, normalSource, uvSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.white
        material.isDoubleSided = true
        material.lightingModel = .physicallyBased
        geometry.materials = [material]
        return geometry
    }
}
