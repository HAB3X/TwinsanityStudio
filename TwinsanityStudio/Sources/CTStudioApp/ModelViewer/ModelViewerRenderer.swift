import Metal
import MetalKit
import CoreGraphics
import simd
import CTModels

/// Tightly-packed, GPU-ready vertex layout: 12 sequential `Float`s (48
/// bytes), no `SIMD3<Float>` fields. This matters — `SIMD3<Float>` has a
/// 16-byte Swift *stride* (not 12), so a buffer of `StaticVertex` values
/// uploaded directly to the GPU would silently misalign every attribute
/// after the first. Building a flat scalar struct sidesteps that entirely:
/// what you see here is exactly what's in the `MTLBuffer`.
struct ModelVertexGPU {
    var px, py, pz: Float
    var nx, ny, nz: Float
    var u, v: Float
    var r, g, b, a: Float
}

/// One submesh's GPU resources: its own vertex/index buffers (submeshes
/// have independent vertex streams, since each can use a different
/// triangle-strip connectivity pattern) and its resolved texture, if any.
private struct GPUSubmesh {
    /// Index into the source `ResolvedModelAsset.mesh.submeshes` — *not*
    /// necessarily this array's own index, since submeshes with no
    /// vertices are skipped during upload and would otherwise shift
    /// everything after them out of alignment with
    /// `ModelViewerRenderer.hiddenSubmeshIndices`.
    let originalIndex: Int
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let texture: MTLTexture
}

/// Matches the Metal shader's `Uniforms` struct byte-for-byte:
/// `simd_float4x4` is already MSL-`float4x4`-compatible (column-major, 64
/// bytes), and `SIMD3<Float>` as the last field naturally gets the same
/// 16-byte stride MSL gives a trailing `float3` in a constant-buffer struct
/// — no manual padding needed on either side.
private struct Uniforms {
    var modelViewProjection: simd_float4x4
    var modelMatrix: simd_float4x4
    var lightDirection: SIMD3<Float>
}

/// Device-level Metal state shared by every `ModelViewerRenderer` instance:
/// the compiled shader library, both pipeline states, depth/sampler state,
/// and the 1×1 fallback texture. None of this depends on which asset is
/// being shown, but building it means compiling MSL source and linking a
/// pipeline — tens of milliseconds of real work. The old `init?` rebuilt
/// all of it from scratch per asset, which was invisible when the Model
/// Viewer opened once per session; it stopped being invisible once the
/// composite preview (`CompositePreviewView`) started creating a fresh
/// `ModelViewerRenderer` on every single sidebar click. Built once, lazily,
/// on first use, and reused for the process's lifetime.
private final class ModelViewerGPUContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let linePipelineState: MTLRenderPipelineState?
    let collisionLinePipelineState: MTLRenderPipelineState?
    let collisionLineColoredPipelineState: MTLRenderPipelineState?
    let depthState: MTLDepthStencilState
    let samplerState: MTLSamplerState
    let fallbackTexture: MTLTexture

    static let shared: ModelViewerGPUContext? = ModelViewerGPUContext()

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = queue

        guard let library = try? device.makeLibrary(source: ModelViewerRenderer.shaderSource, options: nil) else {
            return nil
        }
        let vertexFunction = library.makeFunction(name: "vertex_main")
        let fragmentFunction = library.makeFunction(name: "fragment_main")

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.stride * 3
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .float2
        vertexDescriptor.attributes[2].offset = MemoryLayout<Float>.stride * 6
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.attributes[3].format = .float4
        vertexDescriptor.attributes[3].offset = MemoryLayout<Float>.stride * 8
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<ModelVertexGPU>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
            return nil
        }
        self.pipelineState = pipelineState

        if let lineVertexFn = library.makeFunction(name: "vertex_line"), let lineFragmentFn = library.makeFunction(name: "fragment_line") {
            let lineDescriptor = MTLRenderPipelineDescriptor()
            lineDescriptor.vertexFunction = lineVertexFn
            lineDescriptor.fragmentFunction = lineFragmentFn
            lineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            lineDescriptor.depthAttachmentPixelFormat = .depth32Float
            linePipelineState = try? device.makeRenderPipelineState(descriptor: lineDescriptor)
        } else {
            linePipelineState = nil
        }

        if let lineVertexFn = library.makeFunction(name: "vertex_line"), let collisionFragmentFn = library.makeFunction(name: "fragment_line_collision") {
            let collisionLineDescriptor = MTLRenderPipelineDescriptor()
            collisionLineDescriptor.vertexFunction = lineVertexFn
            collisionLineDescriptor.fragmentFunction = collisionFragmentFn
            collisionLineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            collisionLineDescriptor.colorAttachments[0].isBlendingEnabled = true
            collisionLineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            collisionLineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            collisionLineDescriptor.depthAttachmentPixelFormat = .depth32Float
            collisionLinePipelineState = try? device.makeRenderPipelineState(descriptor: collisionLineDescriptor)
        } else {
            collisionLinePipelineState = nil
        }

        if let colorLineVertexFn = library.makeFunction(name: "vertex_line_colored"), let colorLineFragmentFn = library.makeFunction(name: "fragment_line_colored") {
            let coloredDescriptor = MTLRenderPipelineDescriptor()
            coloredDescriptor.vertexFunction = colorLineVertexFn
            coloredDescriptor.fragmentFunction = colorLineFragmentFn
            coloredDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            coloredDescriptor.colorAttachments[0].isBlendingEnabled = true
            coloredDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            coloredDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            coloredDescriptor.depthAttachmentPixelFormat = .depth32Float
            collisionLineColoredPipelineState = try? device.makeRenderPipelineState(descriptor: coloredDescriptor)
        } else {
            collisionLineColoredPipelineState = nil
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }
        self.depthState = depthState

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.samplerState = samplerState

        guard let fallback = ModelViewerRenderer.makeSolidTexture(device: device, rgba: (255, 255, 255, 255)) else { return nil }
        self.fallbackTexture = fallback
    }
}

/// How the Collision Viewer colors wireframe edges (blueprint 4.1,
/// "Collision Mesh & Trigger Overlays"). `bySurfaceID` distinguishes raw
/// `CollisionTriangle.surfaceID` values from each other visually — it is
/// deliberately *not* the blueprint's literal "Red = Death, Green = Trigger,
/// Blue = Solid" scheme, because this codebase has no verified mapping from
/// a surface ID to that kind of semantic category (the undecoded
/// `CollisionSurface` record and `Object`/`Script` layer are where that
/// classification would actually live — see `CollisionTriangle`'s doc
/// comment). Coloring by the real, decoded ID is still genuinely useful
/// (it makes distinct physical-material regions visually obvious) without
/// asserting something unverified.
public enum CollisionColorMode: Sendable {
    case solid
    case bySurfaceID
}

/// Drives the Model Viewer's `MTKView`: uploads a `ResolvedModelAsset`'s
/// geometry and textures to the GPU once, then renders it every frame with
/// simple directional + ambient lighting and an orbit camera.
///
/// Deliberately renders the mesh in its bind pose only — see
/// `AnimationPlaybackController` for why animation playback here drives a
/// skeleton joint visualization rather than deforming these vertices.
final class ModelViewerRenderer: NSObject, MTKViewDelegate {
    private let context: ModelViewerGPUContext
    var device: MTLDevice { context.device }

    private var submeshes: [GPUSubmesh] = []
    private var boundsCenter: SIMD3<Float> = .zero
    private var boundsRadius: Float = 1

    /// Camera orbit state, driven by `InteractiveMTKView`'s mouse handling.
    var yaw: Float = .pi * 0.25
    var pitch: Float = .pi * 0.15
    var distanceMultiplier: Float = 2.4

    /// Optional skeleton overlay, drawn as connected line segments between
    /// joints. Set by `AnimationPlaybackController` as playback advances.
    var skeletonJointWorldPositions: [(SIMD3<Float>, SIMD3<Float>)] = []

    /// "Granular Component Visibility": submesh indices (matching
    /// `ResolvedModelAsset.mesh.submeshes`/`.submeshMaterials`) to skip
    /// during the draw pass. Indices, not identity, because that's the
    /// granularity a submesh actually exists at on the GPU side — there's
    /// no separate "hide this texture" primitive, just "don't draw the
    /// submesh(es) that use it" (see `ComponentVisibilityView`).
    var hiddenSubmeshIndices: Set<Int> = []

    /// Collision wireframe edges (blue), set when this renderer was built
    /// from a `CollisionMesh` rather than a `ResolvedModelAsset`. Drawn with
    /// the same line pipeline machinery as the skeleton overlay, just a
    /// separate pipeline state so the two don't fight over fragment color.
    private var collisionEdgeWorldPositions: [(SIMD3<Float>, SIMD3<Float>)] = []
    /// One color per entry in `collisionEdgeWorldPositions`, derived from
    /// that edge's triangle's raw `surfaceID` (see `CollisionColorMode`'s
    /// doc comment for why this is the raw ID, not an invented semantic
    /// category like "deadly"/"solid").
    private var collisionEdgeColors: [SIMD3<Float>] = []
    public var collisionColorMode: CollisionColorMode = .solid
    /// Every distinct raw `surfaceID` found in the currently loaded
    /// collision mesh, in first-seen order — backs the legend in
    /// `CollisionViewerWindow`.
    public private(set) var collisionSurfaceIDs: [Int] = []

    init?(asset: ResolvedModelAsset) {
        guard let context = ModelViewerGPUContext.shared else { return nil }
        self.context = context
        super.init()
        upload(asset: asset)
    }

    /// Wireframe-only path for "Collision Viewing": no textured submeshes,
    /// just every collision triangle's three edges drawn as lines, with the
    /// orbit camera framed from the collision mesh's own vertex bounds
    /// rather than a `ResolvedModelAsset`'s. Shared edges between adjacent
    /// triangles aren't deduplicated — each triangle contributes its own 3
    /// edges — which draws every internal edge twice; visually harmless
    /// (identical overlapping line segments) and far simpler than an
    /// edge-adjacency pass, which isn't needed for a first working overlay.
    init?(collisionMesh: CollisionMesh) {
        guard let context = ModelViewerGPUContext.shared else { return nil }
        self.context = context
        super.init()
        upload(collisionMesh: collisionMesh)
    }

    private func upload(collisionMesh: CollisionMesh) {
        guard !collisionMesh.vertices.isEmpty else { return }
        var minBound = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var edges: [(SIMD3<Float>, SIMD3<Float>)] = []
        var colors: [SIMD3<Float>] = []
        edges.reserveCapacity(collisionMesh.triangles.count * 3)
        colors.reserveCapacity(collisionMesh.triangles.count * 3)
        var seenSurfaceIDs: [Int] = []
        var seenSurfaceIDSet: Set<Int> = []

        func point(_ index: Int) -> SIMD3<Float>? {
            guard collisionMesh.vertices.indices.contains(index) else { return nil }
            let v = collisionMesh.vertices[index]
            return SIMD3(v.x, v.y, v.z)
        }

        for triangle in collisionMesh.triangles {
            guard let a = point(triangle.vertexIndex1),
                  let b = point(triangle.vertexIndex2),
                  let c = point(triangle.vertexIndex3) else { continue }
            edges.append((a, b))
            edges.append((b, c))
            edges.append((c, a))
            let color = Self.color(forSurfaceID: triangle.surfaceID)
            colors.append(contentsOf: [color, color, color])
            if seenSurfaceIDSet.insert(triangle.surfaceID).inserted {
                seenSurfaceIDs.append(triangle.surfaceID)
            }
        }

        for v in collisionMesh.vertices {
            let p = SIMD3(v.x, v.y, v.z)
            minBound = simd_min(minBound, p)
            maxBound = simd_max(maxBound, p)
        }

        collisionEdgeWorldPositions = edges
        collisionEdgeColors = colors
        collisionSurfaceIDs = seenSurfaceIDs
        if minBound.x <= maxBound.x {
            boundsCenter = (minBound + maxBound) / 2
            let extent = maxBound - minBound
            boundsRadius = max(max(extent.x, extent.y), max(extent.z, 1))
        }
    }

    private func upload(asset: ResolvedModelAsset) {
        let built = Self.buildGPUSubmeshes(mesh: asset.mesh, submeshMaterials: asset.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture)
        submeshes = built.submeshes
        let minBound = built.minBound
        let maxBound = built.maxBound
        if minBound.x <= maxBound.x {
            boundsCenter = (minBound + maxBound) / 2
            let extent = maxBound - minBound
            boundsRadius = max(max(extent.x, extent.y), max(extent.z, 1))
        }
    }

    /// Shared by `ModelViewerRenderer.upload(asset:)` and
    /// `LevelViewerRenderer` (which uploads many objects, each needing the
    /// exact same per-submesh vertex/index/texture upload) — one GPU-upload
    /// implementation instead of two copies that could drift apart.
    fileprivate static func buildGPUSubmeshes(mesh: MeshAsset, submeshMaterials: [ResolvedSubmeshMaterial], device: MTLDevice, fallbackTexture: MTLTexture) -> (submeshes: [GPUSubmesh], minBound: SIMD3<Float>, maxBound: SIMD3<Float>) {
        var minBound = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var gpuSubmeshes: [GPUSubmesh] = []

        for (index, submesh) in mesh.submeshes.enumerated() {
            guard !submesh.vertices.isEmpty else { continue }
            var gpuVertices: [ModelVertexGPU] = []
            gpuVertices.reserveCapacity(submesh.vertices.count)
            for v in submesh.vertices {
                minBound = simd_min(minBound, v.position)
                maxBound = simd_max(maxBound, v.position)
                gpuVertices.append(ModelVertexGPU(
                    px: v.position.x, py: v.position.y, pz: v.position.z,
                    nx: v.normal.x, ny: v.normal.y, nz: v.normal.z,
                    u: v.uv.x, v: v.uv.y,
                    r: Float(v.color.x) / 255.0, g: Float(v.color.y) / 255.0,
                    b: Float(v.color.z) / 255.0, a: Float(v.color.w) / 255.0
                ))
            }

            var indices: [UInt32] = []
            for (a, b, c) in submesh.triangleIndices() {
                indices.append(UInt32(a)); indices.append(UInt32(b)); indices.append(UInt32(c))
            }
            guard !indices.isEmpty,
                  let vertexBuffer = device.makeBuffer(bytes: gpuVertices, length: gpuVertices.count * MemoryLayout<ModelVertexGPU>.stride, options: .storageModeShared),
                  let indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)
            else { continue }

            let texture: MTLTexture
            if let resolvedTexture = index < submeshMaterials.count ? submeshMaterials[index].texture : nil,
               let uploaded = makeTexture(device: device, asset: resolvedTexture) {
                texture = uploaded
            } else {
                texture = fallbackTexture
            }

            gpuSubmeshes.append(GPUSubmesh(originalIndex: index, vertexBuffer: vertexBuffer, indexBuffer: indexBuffer, indexCount: indices.count, texture: texture))
        }

        return (gpuSubmeshes, minBound, maxBound)
    }

    fileprivate static func makeTexture(device: MTLDevice, asset: TextureAsset) -> MTLTexture? {
        guard asset.width > 0, asset.height > 0, asset.rgba.count >= asset.width * asset.height * 4 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: asset.width, height: asset.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        asset.rgba.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, asset.width, asset.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: asset.width * 4
            )
        }
        return texture
    }

    fileprivate static func makeSolidTexture(device: MTLDevice, rgba: (UInt8, UInt8, UInt8, UInt8)) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let pixel: [UInt8] = [rgba.0, rgba.1, rgba.2, rgba.3]
        pixel.withUnsafeBytes { ptr in
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: 4)
        }
        return texture
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = context.commandQueue.makeCommandBuffer()
        else { return }

        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        encode(descriptor: descriptor, commandBuffer: commandBuffer, aspect: aspect)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Renders one frame to an offscreen texture and reads it back as a
    /// `CGImage` — used by `debugSnapshot()` to let the pipeline be verified
    /// without an on-screen window (e.g. from a test), and reusable for any
    /// future thumbnail/export-preview feature.
    func renderOffscreen(width: Int, height: Int) -> CGImage? {
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .shared
        guard let colorTexture = device.makeTexture(descriptor: colorDescriptor) else { return nil }

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        guard let depthTexture = device.makeTexture(descriptor: depthDescriptor) else { return nil }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = colorTexture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.07, 0.07, 0.09, 1)
        passDescriptor.depthAttachment.texture = depthTexture
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.storeAction = .dontCare
        passDescriptor.depthAttachment.clearDepth = 1.0

        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else { return nil }
        encode(descriptor: passDescriptor, commandBuffer: commandBuffer, aspect: Float(width) / Float(height))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixelBytes = [UInt8](repeating: 0, count: width * height * 4)
        pixelBytes.withUnsafeMutableBytes { ptr in
            colorTexture.getBytes(ptr.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        // BGRA (from the texture) -> RGBA for CGImage.
        var rgba = [UInt8](repeating: 0, count: pixelBytes.count)
        for i in stride(from: 0, to: pixelBytes.count, by: 4) {
            rgba[i] = pixelBytes[i + 2]
            rgba[i + 1] = pixelBytes[i + 1]
            rgba[i + 2] = pixelBytes[i]
            rgba[i + 3] = pixelBytes[i + 3]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private func encode(descriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer, aspect: Float) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let projection = Self.perspectiveMatrix(fovYRadians: .pi / 4, aspect: aspect, near: 0.01, far: boundsRadius * 20 + 10)
        let distance = boundsRadius * distanceMultiplier
        let eye = SIMD3<Float>(
            boundsCenter.x + distance * cos(pitch) * sin(yaw),
            boundsCenter.y + distance * sin(pitch),
            boundsCenter.z + distance * cos(pitch) * cos(yaw)
        )
        let view4x4 = Self.lookAtMatrix(eye: eye, center: boundsCenter, up: SIMD3<Float>(0, 1, 0))
        let model = matrix_identity_float4x4
        var uniforms = Uniforms(
            modelViewProjection: projection * view4x4 * model,
            modelMatrix: model,
            lightDirection: normalize(SIMD3<Float>(-0.4, -1.0, -0.3))
        )

        encoder.setRenderPipelineState(context.pipelineState)
        encoder.setDepthStencilState(context.depthState)
        encoder.setFragmentSamplerState(context.samplerState, index: 0)

        for submesh in submeshes where !hiddenSubmeshIndices.contains(submesh.originalIndex) {
            encoder.setVertexBuffer(submesh.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(submesh.texture, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: submesh.indexCount, indexType: .uint32, indexBuffer: submesh.indexBuffer, indexBufferOffset: 0)
        }

        if let linePipelineState = context.linePipelineState, !skeletonJointWorldPositions.isEmpty {
            var lineVertices: [Float] = []
            for (a, b) in skeletonJointWorldPositions {
                lineVertices.append(contentsOf: [a.x, a.y, a.z, b.x, b.y, b.z])
            }
            if let lineBuffer = device.makeBuffer(bytes: lineVertices, length: lineVertices.count * MemoryLayout<Float>.stride, options: .storageModeShared) {
                encoder.setRenderPipelineState(linePipelineState)
                encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: skeletonJointWorldPositions.count * 2)
            }
        }

        if collisionColorMode == .bySurfaceID, let coloredPipelineState = context.collisionLineColoredPipelineState, !collisionEdgeWorldPositions.isEmpty {
            var lineVertices: [Float] = []
            lineVertices.reserveCapacity(collisionEdgeWorldPositions.count * 12)
            for (index, edge) in collisionEdgeWorldPositions.enumerated() {
                let color = collisionEdgeColors[index]
                lineVertices.append(contentsOf: [edge.0.x, edge.0.y, edge.0.z, color.x, color.y, color.z])
                lineVertices.append(contentsOf: [edge.1.x, edge.1.y, edge.1.z, color.x, color.y, color.z])
            }
            if let lineBuffer = device.makeBuffer(bytes: lineVertices, length: lineVertices.count * MemoryLayout<Float>.stride, options: .storageModeShared) {
                encoder.setRenderPipelineState(coloredPipelineState)
                encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: collisionEdgeWorldPositions.count * 2)
            }
        } else if let collisionLinePipelineState = context.collisionLinePipelineState, !collisionEdgeWorldPositions.isEmpty {
            var lineVertices: [Float] = []
            lineVertices.reserveCapacity(collisionEdgeWorldPositions.count * 6)
            for (a, b) in collisionEdgeWorldPositions {
                lineVertices.append(contentsOf: [a.x, a.y, a.z, b.x, b.y, b.z])
            }
            if let lineBuffer = device.makeBuffer(bytes: lineVertices, length: lineVertices.count * MemoryLayout<Float>.stride, options: .storageModeShared) {
                encoder.setRenderPipelineState(collisionLinePipelineState)
                encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: collisionEdgeWorldPositions.count * 2)
            }
        }

        encoder.endEncoding()
    }

    /// `submeshCount`/`hasGeometry`: cheap introspection for diagnostics and
    /// for the sidebar/hub to show "no geometry" instead of opening a
    /// guaranteed-blank viewer.
    var submeshCount: Int { submeshes.count }
    var hasGeometry: Bool { !submeshes.isEmpty }
    var hasCollisionWireframe: Bool { !collisionEdgeWorldPositions.isEmpty }

    /// Deterministic, stable color for a raw collision `surfaceID` — golden-
    /// ratio hue stepping so adjacent IDs land far apart on the color wheel
    /// rather than as a monotonic gradient (which would make neighboring
    /// surface IDs look confusingly similar). This is *not* a claim about
    /// what a surface ID means (see `CollisionTriangle.surfaceID`'s doc
    /// comment — that mapping to "deadly"/"solid"/etc. isn't decoded), only
    /// a way to tell different raw IDs apart visually. `nonisolated` and
    /// `static` so the `CollisionViewerWindow` legend can compute the exact
    /// same colors without holding a live renderer.
    public static func color(forSurfaceID surfaceID: Int) -> SIMD3<Float> {
        let goldenRatioConjugate: Double = 0.6180339887498949
        // `UInt(bitPattern:)` sidesteps sign entirely (a negative surfaceID
        // is unexpected but not impossible for an undecoded raw field), and
        // the explicit `.truncatingRemainder` + `+ 1 % 1` clamp guarantees
        // `hue` lands in [0, 1) before it ever reaches `hsvToRGB`, where a
        // negative value would otherwise produce an out-of-range `i % 6`.
        let bucket = UInt(bitPattern: surfaceID) % 1000
        var hue = (Double(bucket) / 1000.0 * goldenRatioConjugate).truncatingRemainder(dividingBy: 1.0)
        if hue < 0 { hue += 1 }
        return hsvToRGB(h: hue, s: 0.62, v: 0.95)
    }

    private static func hsvToRGB(h: Double, s: Double, v: Double) -> SIMD3<Float> {
        let i = Int(h * 6)
        let f = h * 6 - Double(i)
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
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

    // MARK: - Matrix helpers (simd has no built-in perspective/lookAt)

    fileprivate static func perspectiveMatrix(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
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

    fileprivate static func lookAtMatrix(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
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

    // MARK: - Shader source

    fileprivate static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
        float2 uv [[attribute(2)]];
        float4 color [[attribute(3)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float3 worldNormal;
        float2 uv;
        float4 color;
    };

    struct Uniforms {
        float4x4 modelViewProjection;
        float4x4 modelMatrix;
        float3 lightDirection;
    };

    vertex VertexOut vertex_main(VertexIn in [[stage_in]], constant Uniforms &uniforms [[buffer(1)]]) {
        VertexOut out;
        out.position = uniforms.modelViewProjection * float4(in.position, 1.0);
        out.worldNormal = normalize((uniforms.modelMatrix * float4(in.normal, 0.0)).xyz);
        out.uv = in.uv;
        out.color = in.color;
        return out;
    }

    fragment float4 fragment_main(VertexOut in [[stage_in]],
                                   texture2d<float> colorTexture [[texture(0)]],
                                   sampler textureSampler [[sampler(0)]],
                                   constant Uniforms &uniforms [[buffer(1)]]) {
        float4 texColor = colorTexture.sample(textureSampler, in.uv);
        // Skinned vertices don't currently decode a real normal (SkinParser
        // leaves it zero — the Skin format's own per-vertex normal isn't
        // wired up yet); normalize()-ing a zero vector is undefined, so
        // treat a degenerate normal as "ambient only" instead of feeding it
        // into the dot product. `abs(dot(...))` rather than `max(...,0)`:
        // there's no back-face culling in this viewer (both sides of thin
        // geometry are visible), so lighting both faces of a surface keeps
        // the back side from reading as flat-black — appropriate for an
        // inspection tool where seeing the geometry matters more than
        // single-sided physical lighting accuracy.
        float normalLength = length(in.worldNormal);
        float diffuse = normalLength > 0.0001 ? abs(dot(in.worldNormal / normalLength, normalize(-uniforms.lightDirection))) : 0.0;
        float lighting = min(0.6 + diffuse * 0.5, 1.0);
        float3 base = texColor.rgb * in.color.rgb;
        return float4(base * lighting, texColor.a * in.color.a);
    }

    struct LineOut {
        float4 position [[position]];
    };

    vertex LineOut vertex_line(uint vertexID [[vertex_id]],
                                const device packed_float3 *positions [[buffer(0)]],
                                constant Uniforms &uniforms [[buffer(1)]]) {
        LineOut out;
        out.position = uniforms.modelViewProjection * float4(positions[vertexID], 1.0);
        return out;
    }

    fragment float4 fragment_line(LineOut in [[stage_in]]) {
        return float4(1.0, 0.65, 0.0, 1.0);
    }

    fragment float4 fragment_line_collision(LineOut in [[stage_in]]) {
        return float4(0.25, 0.7, 1.0, 0.9);
    }

    struct LineVertexColorIn {
        packed_float3 position;
        packed_float3 color;
    };

    struct LineColorOut {
        float4 position [[position]];
        float4 color;
    };

    vertex LineColorOut vertex_line_colored(uint vertexID [[vertex_id]],
                                             const device LineVertexColorIn *vertices [[buffer(0)]],
                                             constant Uniforms &uniforms [[buffer(1)]]) {
        LineColorOut out;
        out.position = uniforms.modelViewProjection * float4(vertices[vertexID].position, 1.0);
        out.color = float4(vertices[vertexID].color, 0.9);
        return out;
    }

    fragment float4 fragment_line_colored(LineColorOut in [[stage_in]]) {
        return in.color;
    }
    """
}

/// One resolved scenery placement, uploaded once and drawn every frame at
/// its own world position.
private struct GPULevelObject {
    let worldPosition: SIMD3<Float>
    let submeshes: [GPUSubmesh]
}

/// "Scenery/Level Assembly": draws every resolved placement from a
/// `SceneryAsset` in one scene, each positioned at its own world-space
/// translation. Shares `ModelViewerGPUContext`/`GPUSubmesh` upload logic
/// with `ModelViewerRenderer` — the only real difference is drawing many
/// objects with per-object model matrices instead of one object at identity.
///
/// Rotation/scale from each placement's decoded 4-row matrix are
/// deliberately **not** applied — only translation (row 3) is, the same
/// "position is trustworthy, full matrix orientation isn't independently
/// confirmed" simplification `ModelViewerWindow.bindPoseSkeletonSegments()`
/// already makes for joint matrices. Objects will show up in the right
/// place but not necessarily facing the right way yet.
final class LevelViewerRenderer: NSObject, MTKViewDelegate {
    private let context: ModelViewerGPUContext
    var device: MTLDevice { context.device }

    private var objects: [GPULevelObject] = []
    private var boundsCenter: SIMD3<Float> = .zero
    private var boundsRadius: Float = 10

    var yaw: Float = .pi * 0.25
    var pitch: Float = .pi * 0.3
    var distanceMultiplier: Float = 1.4

    /// - Parameter placements: each resolved object's world position
    ///   (translation-only, see the type doc comment) paired with its
    ///   fully textured mesh.
    init?(placements: [(worldPosition: SIMD3<Float>, asset: ResolvedModelAsset)]) {
        guard let context = ModelViewerGPUContext.shared else { return nil }
        self.context = context
        super.init()
        upload(placements: placements)
    }

    private func upload(placements: [(worldPosition: SIMD3<Float>, asset: ResolvedModelAsset)]) {
        var minBound = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var levelObjects: [GPULevelObject] = []
        levelObjects.reserveCapacity(placements.count)

        for (worldPosition, asset) in placements {
            let built = ModelViewerRenderer.buildGPUSubmeshes(mesh: asset.mesh, submeshMaterials: asset.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture)
            guard !built.submeshes.isEmpty else { continue }
            levelObjects.append(GPULevelObject(worldPosition: worldPosition, submeshes: built.submeshes))
            // Bounds are tracked from placement position, not local mesh
            // extent — for a whole-level view, "where objects are" matters
            // far more than any one object's own size.
            minBound = simd_min(minBound, worldPosition)
            maxBound = simd_max(maxBound, worldPosition)
        }

        objects = levelObjects
        if minBound.x <= maxBound.x {
            boundsCenter = (minBound + maxBound) / 2
            let extent = maxBound - minBound
            boundsRadius = max(max(extent.x, extent.y), max(extent.z, 10))
        }
    }

    var hasGeometry: Bool { !objects.isEmpty }
    var objectCount: Int { objects.count }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let projection = ModelViewerRenderer.perspectiveMatrix(fovYRadians: .pi / 4, aspect: aspect, near: 0.05, far: boundsRadius * 20 + 50)
        let distance = boundsRadius * distanceMultiplier
        let eye = SIMD3<Float>(
            boundsCenter.x + distance * cos(pitch) * sin(yaw),
            boundsCenter.y + distance * sin(pitch),
            boundsCenter.z + distance * cos(pitch) * cos(yaw)
        )
        let view4x4 = ModelViewerRenderer.lookAtMatrix(eye: eye, center: boundsCenter, up: SIMD3<Float>(0, 1, 0))
        let viewProjection = projection * view4x4
        let lightDirection = normalize(SIMD3<Float>(-0.4, -1.0, -0.3))

        encoder.setRenderPipelineState(context.pipelineState)
        encoder.setDepthStencilState(context.depthState)
        encoder.setFragmentSamplerState(context.samplerState, index: 0)

        for object in objects {
            let model = simd_float4x4(translation: object.worldPosition)
            var uniforms = Uniforms(modelViewProjection: viewProjection * model, modelMatrix: model, lightDirection: lightDirection)
            for submesh in object.submeshes {
                encoder.setVertexBuffer(submesh.vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setFragmentTexture(submesh.texture, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: submesh.indexCount, indexType: .uint32, indexBuffer: submesh.indexBuffer, indexBufferOffset: 0)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

private extension simd_float4x4 {
    init(translation: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
    }
}
