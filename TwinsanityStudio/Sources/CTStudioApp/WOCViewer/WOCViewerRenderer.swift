import Metal
import MetalKit
import simd
import CTModels

/// A deliberately small, standalone Metal renderer for WoC content --
/// **not** built on `ModelViewerRenderer`/`LevelViewerRenderer` (that
/// shared class is a 2500+ line, Twinsanity-editor-specific pipeline with
/// gizmo/placement/free-camera machinery this viewer has no use for; see
/// this file's introduction for why a fresh, minimal renderer is the
/// better fit here). Conforms to `OrbitCameraRenderer` purely to get
/// `MetalModelView`/`InteractiveMTKView`'s existing mouse-drag-to-orbit
/// and scroll-to-zoom handling for free -- everything else (pipeline,
/// shaders, buffers) is its own.
///
/// Current geometry: real placed-object positions (`INST`, via
/// `WOCLevelAsset.objects`) drawn as colored point markers. This is
/// **not** real mesh geometry -- `OBJ0`'s per-object mesh boundaries are
/// still unsolved (see `WOCContainerParser`'s doc comment), so there is no
/// reliable "this object's real shape" data to draw yet. Point markers are
/// real, decoded, correctly-positioned data (not placeholders in the
/// fabricated sense), just not the final visual fidelity.
final class WOCViewerRenderer: NSObject, MTKViewDelegate, OrbitCameraRenderer {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pointPipelineState: MTLRenderPipelineState
    private let meshPipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    var yaw: Float = .pi * 0.25
    var pitch: Float = .pi * 0.3
    var distanceMultiplier: Float = 1.6

    private var pointBuffer: MTLBuffer?
    private var pointCount = 0
    private var meshVertexBuffer: MTLBuffer?
    private var meshVertexCount = 0
    private var boundsCenter = SIMD3<Float>.zero
    private var boundsRadius: Float = 50

    private struct PointVertexIn {
        var position: SIMD3<Float>
        var color: SIMD3<Float>
    }

    /// Real triangle geometry from `WOCMeshDecoder` -- unindexed (each
    /// triangle's 3 vertices written out directly) since submesh vertex
    /// counts here are small (tens to low hundreds per object) and this
    /// avoids a second index buffer for what's currently a first working
    /// version.
    private struct MeshVertexIn {
        var position: SIMD3<Float>
        var color: SIMD3<Float>
    }

    private struct Uniforms {
        var modelViewProjection: simd_float4x4
        var pointSize: Float
    }

    init?(objects: [WOCObjectInstance], objectCount: Int, objectMeshes: [MeshAsset] = []) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue

        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil) else { return nil }
        guard let vertexFn = library.makeFunction(name: "woc_vertex_point"),
              let fragmentFn = library.makeFunction(name: "woc_fragment_point") else { return nil }
        guard let meshVertexFn = library.makeFunction(name: "woc_vertex_mesh"),
              let meshFragmentFn = library.makeFunction(name: "woc_fragment_mesh") else { return nil }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.stride * 3
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<PointVertexIn>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFn
        pipelineDescriptor.fragmentFunction = fragmentFn
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        guard let pointPipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else { return nil }
        self.pointPipelineState = pointPipelineState

        let meshVertexDescriptor = MTLVertexDescriptor()
        meshVertexDescriptor.attributes[0].format = .float3
        meshVertexDescriptor.attributes[0].offset = 0
        meshVertexDescriptor.attributes[0].bufferIndex = 0
        meshVertexDescriptor.attributes[1].format = .float3
        meshVertexDescriptor.attributes[1].offset = MemoryLayout<Float>.stride * 3
        meshVertexDescriptor.attributes[1].bufferIndex = 0
        meshVertexDescriptor.layouts[0].stride = MemoryLayout<MeshVertexIn>.stride
        meshVertexDescriptor.layouts[0].stepFunction = .perVertex

        let meshPipelineDescriptor = MTLRenderPipelineDescriptor()
        meshPipelineDescriptor.vertexFunction = meshVertexFn
        meshPipelineDescriptor.fragmentFunction = meshFragmentFn
        meshPipelineDescriptor.vertexDescriptor = meshVertexDescriptor
        meshPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        meshPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        guard let meshPipelineState = try? device.makeRenderPipelineState(descriptor: meshPipelineDescriptor) else { return nil }
        self.meshPipelineState = meshPipelineState

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }
        self.depthState = depthState

        super.init()
        upload(objects: objects, objectCount: objectCount, objectMeshes: objectMeshes)
    }

    /// Deterministic per-`objectIndex` color (golden-ratio hue stepping,
    /// same technique `ModelViewerRenderer.color(forSurfaceID:)` uses) --
    /// distinguishes different real objects from each other visually
    /// without asserting anything about what the object type "means".
    private static func color(forObjectIndex index: UInt32) -> SIMD3<Float> {
        let goldenRatioConjugate: Double = 0.6180339887498949
        var hue = (Double(index % 1000) * goldenRatioConjugate).truncatingRemainder(dividingBy: 1.0)
        if hue < 0 { hue += 1 }
        let i = Int(hue * 6)
        let f = hue * 6 - Double(i)
        let s = 0.62, v = 0.95
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let rgb: (Double, Double, Double)
        switch i % 6 {
        case 0: rgb = (v, t, p)
        case 1: rgb = (q, v, p)
        case 2: rgb = (p, v, t)
        case 3: rgb = (p, q, v)
        case 4: rgb = (t, p, v)
        default: rgb = (v, p, q)
        }
        return SIMD3(Float(rgb.0), Float(rgb.1), Float(rgb.2))
    }

    /// Splits placed objects into two draw sets: real mesh geometry
    /// (`WOCMeshDecoder`-built, when `objectMeshes[objectIndex]` has at
    /// least one real triangle) drawn as actual lit triangles, and a
    /// point marker for everything else -- either this file's `OBJ0`
    /// walk was refused outright (see `WOCLevelAsset.objectMeshes`'s doc
    /// comment) or this specific entry's own chunks decoded to zero
    /// triangles. No rotation is applied to placed meshes yet (see the
    /// same doc comment) -- only real, decoded translation.
    private func upload(objects: [WOCObjectInstance], objectCount: Int, objectMeshes: [MeshAsset]) {
        guard !objects.isEmpty else { pointCount = 0; meshVertexCount = 0; return }

        var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for object in objects {
            minP = simd_min(minP, object.worldPosition)
            maxP = simd_max(maxP, object.worldPosition)
        }
        boundsCenter = (minP + maxP) / 2
        boundsRadius = max(simd_length(maxP - boundsCenter), 1)

        var pointVertices: [PointVertexIn] = []
        var meshVertices: [MeshVertexIn] = []
        for object in objects {
            let color = Self.color(forObjectIndex: object.objectIndex)
            let meshIndex = Int(object.objectIndex)
            if meshIndex >= 0, meshIndex < objectMeshes.count {
                let mesh = objectMeshes[meshIndex]
                var addedAny = false
                for submesh in mesh.submeshes {
                    for (a, b, c) in submesh.triangleIndices() {
                        meshVertices.append(MeshVertexIn(position: submesh.vertices[a].position + object.worldPosition, color: color))
                        meshVertices.append(MeshVertexIn(position: submesh.vertices[b].position + object.worldPosition, color: color))
                        meshVertices.append(MeshVertexIn(position: submesh.vertices[c].position + object.worldPosition, color: color))
                        addedAny = true
                    }
                }
                if addedAny { continue }
            }
            pointVertices.append(PointVertexIn(position: object.worldPosition, color: color))
        }

        if pointVertices.isEmpty {
            pointBuffer = nil
            pointCount = 0
        } else {
            pointBuffer = device.makeBuffer(bytes: pointVertices, length: MemoryLayout<PointVertexIn>.stride * pointVertices.count, options: .storageModeShared)
            pointCount = pointVertices.count
        }

        if meshVertices.isEmpty {
            meshVertexBuffer = nil
            meshVertexCount = 0
        } else {
            meshVertexBuffer = device.makeBuffer(bytes: meshVertices, length: MemoryLayout<MeshVertexIn>.stride * meshVertices.count, options: .storageModeShared)
            meshVertexCount = meshVertices.count
        }
    }

    func resetView() {
        yaw = .pi * 0.25
        pitch = .pi * 0.3
        distanceMultiplier = 1.6
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else { return }

        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let distance = boundsRadius * distanceMultiplier + 1
        let eye = boundsCenter + SIMD3<Float>(
            distance * cos(pitch) * sin(yaw),
            distance * sin(pitch),
            distance * cos(pitch) * cos(yaw)
        )
        let view4 = Self.lookAtMatrix(eye: eye, center: boundsCenter, up: SIMD3<Float>(0, 1, 0))
        let proj = Self.perspectiveMatrix(fovYRadians: .pi / 4, aspect: aspect, near: 0.1, far: max(boundsRadius * 20, 100))
        var uniforms = Uniforms(modelViewProjection: proj * view4, pointSize: 8)

        encoder.setDepthStencilState(depthState)

        if let meshVertexBuffer, meshVertexCount > 0 {
            encoder.setRenderPipelineState(meshPipelineState)
            encoder.setVertexBuffer(meshVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: meshVertexCount)
        }

        encoder.setRenderPipelineState(pointPipelineState)
        if let pointBuffer, pointCount > 0 {
            encoder.setVertexBuffer(pointBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func perspectiveMatrix(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovYRadians * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        )
    }

    private static func lookAtMatrix(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = normalize(eye - center)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        return simd_float4x4(
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        )
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        packed_float3 position;
        packed_float3 color;
    };

    struct Uniforms {
        float4x4 modelViewProjection;
        float pointSize;
    };

    struct VertexOut {
        float4 position [[position]];
        float4 color;
        float pointSize [[point_size]];
    };

    vertex VertexOut woc_vertex_point(uint vertexID [[vertex_id]],
                                       const device VertexIn *vertices [[buffer(0)]],
                                       constant Uniforms &uniforms [[buffer(1)]]) {
        VertexOut out;
        out.position = uniforms.modelViewProjection * float4(vertices[vertexID].position, 1.0);
        out.color = float4(vertices[vertexID].color, 1.0);
        out.pointSize = uniforms.pointSize;
        return out;
    }

    fragment float4 woc_fragment_point(VertexOut in [[stage_in]], float2 pointCoord [[point_coord]]) {
        float dist = length(pointCoord - float2(0.5, 0.5));
        if (dist > 0.5) discard_fragment();
        return in.color;
    }

    struct MeshVertexOut {
        float4 position [[position]];
        float4 color;
        float3 worldPosition;
    };

    vertex MeshVertexOut woc_vertex_mesh(uint vertexID [[vertex_id]],
                                          const device VertexIn *vertices [[buffer(0)]],
                                          constant Uniforms &uniforms [[buffer(1)]]) {
        MeshVertexOut out;
        float3 worldPos = vertices[vertexID].position;
        out.position = uniforms.modelViewProjection * float4(worldPos, 1.0);
        out.color = float4(vertices[vertexID].color, 1.0);
        out.worldPosition = worldPos;
        return out;
    }

    // Flat shading from screen-space position derivatives -- no real
    // per-vertex normals are decoded yet (see WOCMeshDecoder's doc
    // comment), so this derives a per-triangle face normal cheaply
    // instead of asserting fabricated per-vertex normal data.
    fragment float4 woc_fragment_mesh(MeshVertexOut in [[stage_in]]) {
        float3 dx = dfdx(in.worldPosition);
        float3 dy = dfdy(in.worldPosition);
        float3 normal = normalize(cross(dx, dy));
        float3 lightDir = normalize(float3(0.4, 0.8, 0.5));
        float diff = max(dot(normal, lightDir), 0.0);
        float shade = 0.35 + diff * 0.65;
        return float4(in.color.rgb * shade, 1.0);
    }
    """
}
