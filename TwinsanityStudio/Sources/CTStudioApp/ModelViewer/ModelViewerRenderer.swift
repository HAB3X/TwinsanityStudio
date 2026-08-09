import Metal
import MetalKit
import CoreGraphics
import QuartzCore
import simd
import CTModels
import CTParsers

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
/// Not `private` — `skinVertices(submesh:skinningMatrices:)` below takes
/// this type directly, and a synthetic-weight regression test (the
/// "totalWeight renormalization" fix) needs to construct one without going
/// through a full skeleton/animation-track pipeline.
struct GPUSubmesh {
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
    /// Bind-space (unanimated) vertex data, retained alongside the GPU
    /// buffer so real skeletal animation (`AnimationSkeletonBinding`) can
    /// re-skin *from bind pose* every frame — never from the previous
    /// frame's already-deformed result, which would compound error. Empty
    /// for non-skinned submeshes (rigid scenery/props, and the Level
    /// Viewer's placeholder markers), which never need re-skinning.
    let bindVertices: [StaticVertex]
    let jointIndices: [SIMD4<UInt16>]
    let jointWeights: [SIMD4<Float>]
}

/// A real, confirmed fix for "massive level rendering" (performance
/// mandate): a `SceneryData`/`Instance` collection can carry
/// hundreds/thousands of placements, and — before this — every single
/// one independently re-uploaded and re-copied its own `MTLTexture` even
/// when many placements share the exact same underlying texture (the
/// overwhelmingly common case: dozens of identical crate/prop/enemy
/// placements). This cache is scoped to *one* `upload()` call
/// (constructed fresh each time a level loads), never a persistent
/// cross-file cache — `TextureAsset.id` is a per-file on-disk record ID,
/// not a globally unique one (see `ResolvedModelAsset.id`'s own doc
/// comment on exactly this), so caching by that ID across different
/// files would risk silently reusing the wrong texture. Within one
/// file's own resolved placements it's a completely safe, meaningful
/// win: they all came from the same `GraphicsAssetIndex`, so the same ID
/// really is the same real texture.
final class TextureUploadCache {
    private var textures: [UInt32: MTLTexture] = [:]

    func texture(for id: UInt32) -> MTLTexture? { textures[id] }
    func store(_ texture: MTLTexture, for id: UInt32) { textures[id] = texture }
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
    /// "Chunk-Based Architecture" (Part 2): fills a translucent quad —
    /// the real boundary "load wall" geometry decoded from `ChunkLinks` —
    /// using the same interleaved position+color vertex layout as
    /// `collisionLineColoredPipelineState`, just drawn as triangles at a
    /// low, see-through alpha instead of lines.
    let translucentQuadPipelineState: MTLRenderPipelineState?
    let depthState: MTLDepthStencilState
    /// Same depth comparison as `depthState` but no depth *write* — a
    /// translucent overlay quad shouldn't occlude whatever draws after it
    /// in the same frame, only be correctly occluded by opaque geometry
    /// already in the depth buffer.
    let translucentDepthState: MTLDepthStencilState
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

        if let colorLineVertexFn = library.makeFunction(name: "vertex_line_colored"), let translucentFragmentFn = library.makeFunction(name: "fragment_translucent_quad") {
            let translucentDescriptor = MTLRenderPipelineDescriptor()
            translucentDescriptor.vertexFunction = colorLineVertexFn
            translucentDescriptor.fragmentFunction = translucentFragmentFn
            translucentDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            translucentDescriptor.colorAttachments[0].isBlendingEnabled = true
            translucentDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            translucentDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            translucentDescriptor.depthAttachmentPixelFormat = .depth32Float
            translucentQuadPipelineState = try? device.makeRenderPipelineState(descriptor: translucentDescriptor)
        } else {
            translucentQuadPipelineState = nil
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }
        self.depthState = depthState

        let translucentDepthDescriptor = MTLDepthStencilDescriptor()
        translucentDepthDescriptor.depthCompareFunction = .less
        translucentDepthDescriptor.isDepthWriteEnabled = false
        guard let translucentDepthState = device.makeDepthStencilState(descriptor: translucentDepthDescriptor) else { return nil }
        self.translucentDepthState = translucentDepthState

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

    /// "Shader Graph Editor" (roadmap 5.4): when set, the main mesh draw
    /// uses this pipeline instead of `context.pipelineState` — an
    /// instance-level override, never touching the shared singleton other
    /// renderer instances (Model Hub thumbnails, Level Viewer previews,
    /// ...) still draw with. `applyShaderGraph` builds this from real
    /// compiled MSL; `clearShaderGraphOverride` reverts to the default.
    private var customPipelineState: MTLRenderPipelineState?

    enum ShaderGraphApplyError: Error {
        case compileFailed(String)
        case functionNotFound
        case pipelineCreationFailed
    }

    /// Compiles `mslFragmentSource` (real MSL emitted by
    /// `ShaderGraphCompiler.compile`) alongside the base shader library's
    /// existing `vertex_main`/struct declarations, builds a real pipeline
    /// state reusing the exact same vertex descriptor/blend/pixel-format
    /// setup `ModelViewerGPUContext`'s default pipeline uses, and swaps it
    /// in for this renderer instance's main mesh draw.
    func applyShaderGraph(mslFragmentSource: String, functionName: String) -> Result<Void, ShaderGraphApplyError> {
        let combinedSource = Self.shaderSource + "\n" + mslFragmentSource
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: combinedSource, options: nil)
        } catch {
            return .failure(.compileFailed(error.localizedDescription))
        }
        guard let vertexFn = library.makeFunction(name: "vertex_main"), let fragmentFn = library.makeFunction(name: functionName) else {
            return .failure(.functionNotFound)
        }

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
        pipelineDescriptor.vertexFunction = vertexFn
        pipelineDescriptor.fragmentFunction = fragmentFn
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        guard let newPipeline = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
            return .failure(.pipelineCreationFailed)
        }
        customPipelineState = newPipeline
        return .success(())
    }

    func clearShaderGraphOverride() {
        customPipelineState = nil
    }

    private var submeshes: [GPUSubmesh] = []
    private var boundsCenter: SIMD3<Float> = .zero
    private var boundsRadius: Float = 1

    /// Camera orbit state, driven by `InteractiveMTKView`'s mouse handling.
    var yaw: Float = .pi * 0.25
    var pitch: Float = .pi * 0.15
    var distanceMultiplier: Float = 2.4

    /// Optional skeleton overlay, drawn as connected line segments between
    /// joints. Set by `AnimationPlaybackController` as playback advances.
    ///
    /// `didSet` rebuilds `skeletonLineBuffer` right here, once, instead of
    /// `draw(in:)` calling `device.makeBuffer` from scratch on every single
    /// rendered frame (this view renders continuously at 20 fps — see
    /// `MetalModelView` — regardless of whether this array actually changed
    /// since the last frame). Scrubbing an animation still rebuilds the
    /// buffer exactly as often as the joint positions actually change; it's
    /// the ~20/sec redundant rebuilds *between* scrub events that this cuts.
    var skeletonJointWorldPositions: [(SIMD3<Float>, SIMD3<Float>)] = [] {
        didSet { skeletonLineBuffer = Self.makeLineBuffer(device: device, segments: skeletonJointWorldPositions) }
    }
    private var skeletonLineBuffer: MTLBuffer?

    /// "Collision Mask Alignment": the real per-object `GI_CollisionData`
    /// box(es) for the currently-shown asset (`ResolvedModelAsset.skeleton?
    /// .collisionData`), drawn as orange wireframe boxes in the *same*
    /// model-space transform as the mesh itself — since these corner
    /// points are already stored in the object's own local/bind space
    /// (verified against real data: they come out as clean ± min/max
    /// triples, e.g. exactly `±0.6` on every axis), no separate alignment
    /// transform is needed here at all; drawing them through the model's
    /// own `modelViewProjection` uniform *is* the correct alignment.
    var collisionVolumeWorldPositions: [(SIMD3<Float>, SIMD3<Float>)] = [] {
        didSet {
            collisionVolumeLineBuffer = Self.makeColoredLineBuffer(
                device: device, segments: collisionVolumeWorldPositions,
                colors: [SIMD3<Float>](repeating: SIMD3(0.95, 0.6, 0.1), count: collisionVolumeWorldPositions.count)
            )
        }
    }
    private var collisionVolumeLineBuffer: MTLBuffer?

    /// "Procedural Collision Decimation" (roadmap 4.4): the real, computed
    /// oriented bounding box from `CollisionDecimator`, drawn as a cyan
    /// wireframe in the same model-space transform as the mesh (same
    /// reasoning as `collisionVolumeWorldPositions` above — no separate
    /// alignment needed, the corners are already in the mesh's own local
    /// space). Distinct color/buffer from the real `GI_CollisionData`
    /// overlay so a user can tell "decoded from the game" apart from
    /// "computed by this tool" at a glance.
    var proceduralOBBWorldPositions: [(SIMD3<Float>, SIMD3<Float>)] = [] {
        didSet {
            proceduralOBBLineBuffer = Self.makeColoredLineBuffer(
                device: device, segments: proceduralOBBWorldPositions,
                colors: [SIMD3<Float>](repeating: SIMD3(0.3, 0.85, 0.95), count: proceduralOBBWorldPositions.count)
            )
        }
    }
    private var proceduralOBBLineBuffer: MTLBuffer?

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
    /// Both buffers below are built once in `upload(collisionMesh:)` and
    /// reused for the mesh's whole lifetime — collision geometry never
    /// changes after load (unlike the skeleton overlay), so rebuilding
    /// either from scratch every frame (the previous behavior) bought
    /// nothing; `collisionColorMode` just picks which cached buffer
    /// `draw(in:)` binds.
    private var collisionLineBuffer: MTLBuffer?
    private var collisionLineColoredBuffer: MTLBuffer?
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
        collisionLineBuffer = Self.makeLineBuffer(device: device, segments: edges)
        collisionLineColoredBuffer = Self.makeColoredLineBuffer(device: device, segments: edges, colors: colors)
        if minBound.x <= maxBound.x {
            boundsCenter = (minBound + maxBound) / 2
            let extent = maxBound - minBound
            boundsRadius = max(max(extent.x, extent.y), max(extent.z, 1))
        }
    }

    /// Shared by the skeleton overlay and the solid-color collision
    /// wireframe: `count * 2` `packed_float3` positions (one pair per
    /// segment), matching `vertex_line`'s expected buffer layout exactly.
    private static func makeLineBuffer(device: MTLDevice, segments: [(SIMD3<Float>, SIMD3<Float>)]) -> MTLBuffer? {
        guard !segments.isEmpty else { return nil }
        var floats: [Float] = []
        floats.reserveCapacity(segments.count * 6)
        for (a, b) in segments {
            floats.append(contentsOf: [a.x, a.y, a.z, b.x, b.y, b.z])
        }
        return device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    /// Interleaved position+color buffer for the by-surface-ID collision
    /// wireframe, matching `vertex_line_colored`'s `LineVertexColorIn`
    /// layout (`packed_float3` position, `packed_float3` color, back to
    /// back — see that shader's doc comment).
    /// "Collision Mask Alignment": box-edge line segments spanning the
    /// axis-aligned bounds of `corners` — not assuming any particular
    /// ordering of the input points (verified against real data as clean
    /// ± min/max triples, but not a confirmed corner-winding order), just
    /// their overall extent, which is exactly what "a box that encapsulates
    /// this" needs regardless of how the 8 points happen to be ordered on
    /// disk.
    static func collisionBoxEdges(corners: [SIMD4<Float>]) -> [(SIMD3<Float>, SIMD3<Float>)] {
        guard !corners.isEmpty else { return [] }
        var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for c in corners {
            let p = SIMD3(c.x, c.y, c.z)
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        let c000 = SIMD3(minP.x, minP.y, minP.z), c100 = SIMD3(maxP.x, minP.y, minP.z)
        let c010 = SIMD3(minP.x, maxP.y, minP.z), c110 = SIMD3(maxP.x, maxP.y, minP.z)
        let c001 = SIMD3(minP.x, minP.y, maxP.z), c101 = SIMD3(maxP.x, minP.y, maxP.z)
        let c011 = SIMD3(minP.x, maxP.y, maxP.z), c111 = SIMD3(maxP.x, maxP.y, maxP.z)
        return [
            (c000, c100), (c100, c110), (c110, c010), (c010, c000),
            (c001, c101), (c101, c111), (c111, c011), (c011, c001),
            (c000, c001), (c100, c101), (c110, c111), (c010, c011)
        ]
    }

    /// "Procedural Collision Decimation" (roadmap 4.4): the 12 edges of a
    /// real, computed oriented bounding box — unlike `collisionBoxEdges`,
    /// this draws the box's *actual* oriented corners directly (no
    /// re-AABB'ing), since `CollisionDecimator`'s corners are already the
    /// real box this tool computed, not on-disk points of unconfirmed
    /// ordering.
    static func orientedBoxEdges(corners: [SIMD3<Float>]) -> [(SIMD3<Float>, SIMD3<Float>)] {
        guard corners.count == 8 else { return [] }
        return [
            (corners[0], corners[1]), (corners[1], corners[2]), (corners[2], corners[3]), (corners[3], corners[0]),
            (corners[4], corners[5]), (corners[5], corners[6]), (corners[6], corners[7]), (corners[7], corners[4]),
            (corners[0], corners[4]), (corners[1], corners[5]), (corners[2], corners[6]), (corners[3], corners[7])
        ]
    }

    private static func makeColoredLineBuffer(device: MTLDevice, segments: [(SIMD3<Float>, SIMD3<Float>)], colors: [SIMD3<Float>]) -> MTLBuffer? {
        guard !segments.isEmpty, segments.count == colors.count else { return nil }
        var floats: [Float] = []
        floats.reserveCapacity(segments.count * 12)
        for (index, edge) in segments.enumerated() {
            let color = colors[index]
            floats.append(contentsOf: [edge.0.x, edge.0.y, edge.0.z, color.x, color.y, color.z])
            floats.append(contentsOf: [edge.1.x, edge.1.y, edge.1.z, color.x, color.y, color.z])
        }
        return device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    /// "Model Viewer & Animation Playback": deforms every skinned submesh's
    /// GPU vertex buffer *in place* (no reallocation — same reasoning as
    /// `skeletonJointWorldPositions`'s own doc comment) to the real,
    /// verified pose at `frameIndex` — see `AnimationSkeletonBinding`'s doc
    /// comment for where this math actually comes from. Always re-skins
    /// from each submesh's own retained bind-space vertices
    /// (`GPUSubmesh.bindVertices`), never from whatever the buffer
    /// currently holds, so scrubbing back and forth never compounds error.
    /// A submesh with no joint weight data (rigid, non-skinned) is left
    /// completely untouched — its buffer was already correct at upload and
    /// nothing here has any basis to change it.
    func applySkeletalPose(skeleton: SkeletonAsset, track: AnimationTrack, frameIndex: Int) {
        let skinning = AnimationSkeletonBinding.skinningMatrices(skeleton: skeleton, track: track, frame: frameIndex)
        for submesh in submeshes {
            guard !submesh.jointWeights.isEmpty else { continue }
            Self.skinVertices(submesh: submesh, skinningMatrices: skinning)
        }
    }

    /// Restores every skinned submesh to its original bind-pose geometry —
    /// called when animation playback stops/resets, or no animation is
    /// selected.
    func resetToBindPose() {
        for submesh in submeshes {
            guard !submesh.jointWeights.isEmpty else { continue }
            Self.writeVertices(submesh.bindVertices, into: submesh.vertexBuffer)
        }
    }

    /// Reads back every vertex position of the first skinned submesh
    /// directly from GPU memory — used by `RealDiscDiagnosticTests` to
    /// verify skeletal deformation actually reaches the vertex buffer
    /// (not just that `AnimationSkeletonBinding` computes different
    /// matrices per frame, which a rendering/write-back bug could still
    /// leave invisible — see that fix's own commit for how this caught
    /// exactly that).
    func debugAllSkinnedVertexPositions() -> [SIMD3<Float>] {
        guard let submesh = submeshes.first(where: { !$0.jointWeights.isEmpty }) else { return [] }
        let stride = MemoryLayout<ModelVertexGPU>.stride
        let vertexCount = submesh.vertexBuffer.length / stride
        let ptr = submesh.vertexBuffer.contents().bindMemory(to: ModelVertexGPU.self, capacity: vertexCount)
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(vertexCount)
        for i in 0..<vertexCount {
            let v = ptr[i]
            result.append(SIMD3(v.px, v.py, v.pz))
        }
        return result
    }

    /// Weighted-blend skinning: each vertex's position/normal is the sum of
    /// up to 4 joint influences (`StaticVertex.color`'s parallel
    /// `jointIndices`/`jointWeights` — "up to 3 active joints per vertex,
    /// padded to 4 lanes," see `MeshSubmesh`'s own doc comment), each joint
    /// contributing `weight * (skinningMatrix * bindSpacePosition)`. Normals
    /// use the same matrix's upper-left 3x3 (rotation/scale, no
    /// translation) — the standard real-time-skinning approximation; it
    /// doesn't correct for non-uniform-scale shearing, which no renderer in
    /// this codebase claims to handle anywhere else either.
    // Not `private` — see `GPUSubmesh`'s own doc comment for why: a
    // synthetic regression test needs to call this directly with a
    // hand-built submesh and a deliberately incomplete `skinningMatrices`
    // dictionary, without standing up a full skeleton/animation pipeline.
    static func skinVertices(submesh: GPUSubmesh, skinningMatrices: [UInt32: simd_float4x4]) {
        var gpuVertices: [ModelVertexGPU] = []
        gpuVertices.reserveCapacity(submesh.bindVertices.count)
        for (i, v) in submesh.bindVertices.enumerated() {
            var skinnedPosition = SIMD3<Float>.zero
            var skinnedNormal = SIMD3<Float>.zero
            // "Animation Player" fix: whether *any* lane actually found a
            // weighted joint influence — the only correct signal for "did
            // real skinning happen here." The blended normal's own
            // magnitude used to stand in for this, but `SkinParser` never
            // decodes real per-vertex normals for skin meshes (they're
            // hard-coded to `.zero` there — a separate, pre-existing gap),
            // so `rotationScale * v.normal` is always the zero vector
            // regardless of whether position skinning succeeded. That made
            // this check misfire 100% of the time for every skinned
            // character, silently discarding the correctly-computed
            // `skinnedPosition` and reverting every vertex back to bind
            // pose every frame — animations decoded and computed correct,
            // per-joint-varying matrices, but nothing ever visibly moved.
            var totalWeight: Float = 0
            if i < submesh.jointIndices.count, i < submesh.jointWeights.count {
                let indices = submesh.jointIndices[i]
                let weights = submesh.jointWeights[i]
                for lane in 0..<4 {
                    let weight = weights[lane]
                    guard weight > 0 else { continue }
                    guard let matrix = skinningMatrices[UInt32(indices[lane])] else { continue }
                    let pos4 = matrix * SIMD4(v.position, 1)
                    skinnedPosition += weight * SIMD3(pos4.x, pos4.y, pos4.z)
                    let rotationScale = simd_float3x3(
                        SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                        SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                        SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
                    )
                    skinnedNormal += weight * (rotationScale * v.normal)
                    totalWeight += weight
                }
            }
            if totalWeight < 0.0001 {
                // No real joint influence found for this vertex (missing
                // weights, or every referenced joint fell outside this
                // frame's skinning matrices) — leave it exactly at bind
                // pose rather than collapsing it to the origin.
                skinnedPosition = v.position
                skinnedNormal = v.normal
            } else {
                // Linear blend skinning is a weighted *average*, not a
                // weighted sum: divide by the weight actually applied
                // rather than assuming it already summed to 1. Source
                // weights normally do sum to ~1, so this is a no-op in the
                // common case — but `skinningMatrices` is a
                // `[UInt32: simd_float4x4]` dictionary, and any lane whose
                // joint index has no entry (an unresolved/out-of-range
                // joint for this frame) gets silently skipped by the
                // `guard let matrix = ...` above, leaving `totalWeight`
                // short of 1 for that vertex specifically. Without this
                // divide, that vertex's position is scaled down toward the
                // coordinate origin by exactly the missing fraction —
                // every affected vertex pulled toward (0,0,0), which is
                // the "model scrunches into a ball" symptom.
                skinnedPosition /= totalWeight
                if simd_length(skinnedNormal) > 0.0001 {
                    skinnedNormal = simd_normalize(skinnedNormal)
                }
            }
            // else: real influence found (skinnedPosition is valid), but
            // the blended normal came out ~zero because the source
            // normals are unpopulated for this format — leave
            // `skinnedNormal` at `.zero` rather than fabricating one;
            // lighting on skinned characters is a known, separate gap,
            // not something this fix invents a value for.
            gpuVertices.append(ModelVertexGPU(
                px: skinnedPosition.x, py: skinnedPosition.y, pz: skinnedPosition.z,
                nx: skinnedNormal.x, ny: skinnedNormal.y, nz: skinnedNormal.z,
                u: v.uv.x, v: v.uv.y,
                r: Float(v.color.x) / 255.0, g: Float(v.color.y) / 255.0,
                b: Float(v.color.z) / 255.0, a: Float(v.color.w) / 255.0
            ))
        }
        Self.writeVertices(gpuVertices, into: submesh.vertexBuffer)
    }

    private static func writeVertices(_ vertices: [StaticVertex], into buffer: MTLBuffer) {
        let gpuVertices = vertices.map {
            ModelVertexGPU(
                px: $0.position.x, py: $0.position.y, pz: $0.position.z,
                nx: $0.normal.x, ny: $0.normal.y, nz: $0.normal.z,
                u: $0.uv.x, v: $0.uv.y,
                r: Float($0.color.x) / 255.0, g: Float($0.color.y) / 255.0,
                b: Float($0.color.z) / 255.0, a: Float($0.color.w) / 255.0
            )
        }
        writeVertices(gpuVertices, into: buffer)
    }

    private static func writeVertices(_ gpuVertices: [ModelVertexGPU], into buffer: MTLBuffer) {
        guard !gpuVertices.isEmpty, buffer.length >= gpuVertices.count * MemoryLayout<ModelVertexGPU>.stride else { return }
        gpuVertices.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: raw.count)
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
    fileprivate static func buildGPUSubmeshes(mesh: MeshAsset, submeshMaterials: [ResolvedSubmeshMaterial], device: MTLDevice, fallbackTexture: MTLTexture, textureCache: TextureUploadCache? = nil) -> (submeshes: [GPUSubmesh], minBound: SIMD3<Float>, maxBound: SIMD3<Float>) {
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
               let uploaded = makeTexture(device: device, asset: resolvedTexture, cache: textureCache) {
                texture = uploaded
            } else {
                texture = fallbackTexture
            }

            gpuSubmeshes.append(GPUSubmesh(
                originalIndex: index, vertexBuffer: vertexBuffer, indexBuffer: indexBuffer, indexCount: indices.count, texture: texture,
                bindVertices: submesh.vertices, jointIndices: submesh.jointIndices, jointWeights: submesh.jointWeights
            ))
        }

        return (gpuSubmeshes, minBound, maxBound)
    }

    /// Internal (not `fileprivate`) so `@testable import` can verify the
    /// cache-reuse behavior directly (`TextureUploadCacheTests`).
    static func makeTexture(device: MTLDevice, asset: TextureAsset, cache: TextureUploadCache? = nil) -> MTLTexture? {
        if let cache, let cached = cache.texture(for: asset.id) { return cached }
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
        cache?.store(texture, for: asset.id)
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

        encoder.setRenderPipelineState(customPipelineState ?? context.pipelineState)
        encoder.setDepthStencilState(context.depthState)
        encoder.setFragmentSamplerState(context.samplerState, index: 0)

        for submesh in submeshes where !hiddenSubmeshIndices.contains(submesh.originalIndex) {
            encoder.setVertexBuffer(submesh.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(submesh.texture, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: submesh.indexCount, indexType: .uint32, indexBuffer: submesh.indexBuffer, indexBufferOffset: 0)
        }

        // Every buffer bound below is built once (in `upload`/the
        // `skeletonJointWorldPositions` `didSet`) and reused here — this
        // view redraws continuously at 20 fps (`MetalModelView`), and
        // `device.makeBuffer` from scratch on every single frame for data
        // that's usually unchanged since the last frame was pure waste.
        if let linePipelineState = context.linePipelineState, let lineBuffer = skeletonLineBuffer, !skeletonJointWorldPositions.isEmpty {
            encoder.setRenderPipelineState(linePipelineState)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: skeletonJointWorldPositions.count * 2)
        }

        // "Collision Mask Alignment" — same colored-line pipeline the
        // by-surface-ID collision viewer and the Level Viewer's gizmo/
        // trigger overlays already share; drawn through this asset's own
        // (identity) model transform, same as every other overlay here.
        if let coloredPipelineState = context.collisionLineColoredPipelineState, let lineBuffer = collisionVolumeLineBuffer, !collisionVolumeWorldPositions.isEmpty {
            encoder.setRenderPipelineState(coloredPipelineState)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: collisionVolumeWorldPositions.count * 2)
        }

        // "Procedural Collision Decimation" (roadmap 4.4) — same colored-
        // line pipeline, cyan instead of orange so it reads as distinct
        // from the real, decoded `GI_CollisionData` overlay above.
        if let coloredPipelineState = context.collisionLineColoredPipelineState, let lineBuffer = proceduralOBBLineBuffer, !proceduralOBBWorldPositions.isEmpty {
            encoder.setRenderPipelineState(coloredPipelineState)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: proceduralOBBWorldPositions.count * 2)
        }

        if collisionColorMode == .bySurfaceID, let coloredPipelineState = context.collisionLineColoredPipelineState, let lineBuffer = collisionLineColoredBuffer, !collisionEdgeWorldPositions.isEmpty {
            encoder.setRenderPipelineState(coloredPipelineState)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: collisionEdgeWorldPositions.count * 2)
        } else if let collisionLinePipelineState = context.collisionLinePipelineState, let lineBuffer = collisionLineBuffer, !collisionEdgeWorldPositions.isEmpty {
            encoder.setRenderPipelineState(collisionLinePipelineState)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: collisionEdgeWorldPositions.count * 2)
        }

        encoder.endEncoding()
    }

    /// `submeshCount`/`hasGeometry`: cheap introspection for diagnostics and
    /// for the sidebar/hub to show "no geometry" instead of opening a
    /// guaranteed-blank viewer.
    var submeshCount: Int { submeshes.count }
    var hasGeometry: Bool { !submeshes.isEmpty }
    var hasCollisionWireframe: Bool { !collisionEdgeWorldPositions.isEmpty }

    /// "F to Focus/Frame" — back to the same angle/distance this renderer
    /// starts a session at.
    func resetView() {
        yaw = .pi * 0.25
        pitch = .pi * 0.15
        distanceMultiplier = 2.4
    }

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

    // MARK: - Frustum culling ("Seamless Full-Map Rendering", Part 1)

    /// The 6 view-frustum planes, extracted straight from a view-projection
    /// matrix via the standard Gribb/Hartmann trick: each plane is one row
    /// of `M` (combined with the clip-space condition it encodes), and a
    /// point's signed distance to it falls out of `plane . (x, y, z, 1)`
    /// divided by the plane normal's length. Built specifically for this
    /// codebase's own `perspectiveMatrix`/`currentViewProjection` convention
    /// — column-vector (`clip = M * v`) and Metal's `[0, 1]` NDC z range
    /// (verified against `perspectiveMatrix`'s own construction: `vz =
    /// -near` maps to `clip.z/w = 0`, `vz = -far` maps to `clip.z/w = 1`) —
    /// not a generic OpenGL `[-1, 1]`-z formula, which would put the near
    /// plane in the wrong place under Metal's convention.
    struct Frustum {
        /// Each plane as `(A, B, C, D)` with the *outward normal already
        /// normalized* — a point is on the inside (visible) half-space when
        /// `A*x + B*y + C*z + D >= 0`, and that dot product is directly a
        /// true signed distance once the normal is unit length, which is
        /// what makes the sphere test below just a `>= -radius` compare.
        private let planes: [SIMD4<Float>]

        init(viewProjection m: simd_float4x4) {
            func row(_ i: Int) -> SIMD4<Float> {
                SIMD4(m.columns.0[i], m.columns.1[i], m.columns.2[i], m.columns.3[i])
            }
            let r0 = row(0), r1 = row(1), r2 = row(2), r3 = row(3)
            // Left/right/bottom/top: standard `r3 ± r0`/`r3 ± r1`, unaffected
            // by the NDC z-range convention. Near/far are Metal-specific:
            // `clip.z >= 0` *is* the near plane directly (not `r3 + r2`,
            // which is the OpenGL `[-1,1]`-z formula), and `clip.w - clip.z
            // >= 0` is the far plane, same as OpenGL.
            let raw = [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r2, r3 - r2]
            planes = raw.map { plane in
                let normalLength = simd_length(SIMD3(plane.x, plane.y, plane.z))
                return normalLength > 0.0001 ? plane / normalLength : plane
            }
        }

        /// Conservative sphere-vs-frustum test: `false` only when the sphere
        /// is provably entirely outside at least one plane. May return
        /// `true` for some spheres that are actually just outside a corner
        /// (the classic false-positive every plane-based frustum test
        /// shares) — acceptable here since the failure mode of a
        /// false-positive is "draw one extra object," not the "object
        /// visibly pops in" a false *negative* would cause.
        func intersects(center: SIMD3<Float>, radius: Float) -> Bool {
            for plane in planes {
                let distance = plane.x * center.x + plane.y * center.y + plane.z * center.z + plane.w
                if distance < -radius { return false }
            }
            return true
        }
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

    fragment float4 fragment_translucent_quad(LineColorOut in [[stage_in]]) {
        return float4(in.color.rgb, 0.28);
    }
    """
}

/// One resolved scenery placement, uploaded once and drawn every frame at
/// its own world position. `worldPosition`/`rotation`/`scale` are `var` —
/// the Forge-style transform gizmo (blueprint 6.1) mutates them directly;
/// everything else about an uploaded object (its GPU geometry) never
/// changes after upload.
/// "Level Editor Overhaul": which of the "Scene Layers" checkbox panel's
/// four groups an object belongs to — drives both draw-time visibility
/// filtering and the "Geometry Only"/"Fully Populated" mode preset.
enum SceneLayer: CaseIterable, Hashable {
    case scenery, actors, triggers, cameras, chunkBoundaries, linkedChunks, aiWaypoints, crossEngine

    var displayName: String {
        switch self {
        case .scenery: return "Scenery / Terrain"
        case .actors: return "Actors / Entities"
        case .triggers: return "Trigger Volumes & Death Planes"
        case .cameras: return "Camera Splines"
        case .chunkBoundaries: return "Chunk Boundaries"
        case .linkedChunks: return "Loaded Neighboring Chunks"
        case .aiWaypoints: return "AI Waypoints"
        case .crossEngine: return "Cross-Engine Data (Wrath of Cortex)"
        }
    }
}

private struct GPULevelObject {
    var worldPosition: SIMD3<Float>
    var rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    var scale: SIMD3<Float> = SIMD3(1, 1, 1)
    let displayName: String
    /// Empty for trigger/camera markers — those draw as line wireframes
    /// (see `overlayLineBuffer`) instead of a solid mesh, but still
    /// participate in `objects` so selection/picking/the sidebar list work
    /// identically across every layer.
    let submeshes: [GPUSubmesh]
    let layer: SceneLayer
    /// Local-space bounding-sphere radius (distance from this object's own
    /// origin to its farthest vertex) — rotation-invariant by construction,
    /// so `LevelViewerRenderer.draw(in:)`'s frustum cull can test it
    /// directly against `worldPosition` without needing the object's
    /// current rotation, only its (interactively editable) `scale`.
    /// "Seamless Full-Map Rendering" (Part 1).
    var boundingRadius: Float = 1
    /// "Direct .RM2 Write-Back": non-nil only for placeholder `Instance`
    /// markers (see `LevelViewerContext.instanceMarkers`) — the on-disk
    /// record this object's transform patches back into on save. `nil` for
    /// ordinary scenery placements and Models-Hub-dropped objects, neither
    /// of which have a verified write path.
    var sourceNode: ChunkNode?
    /// The record's on-disk W component and COM-rotation, preserved
    /// unedited — the gizmo only ever touches XYZ position and the primary
    /// rotation, so these need to survive round-trip to re-encode a valid
    /// 28-byte transform prefix on save.
    var originalPositionW: Float = 0
    var comRotationRaw: SIMD3<UInt16> = .zero
    /// "The Forge Palette" (Part 4C): non-nil only for an object placed
    /// this session via the palette (not yet a real record in the file) —
    /// `objectID` is what a brand-new `Instance` record for it needs, and
    /// `syntheticInstanceID` is a locally-generated ID that doesn't collide
    /// with any real `Instance` already in this level (see
    /// `LevelViewerRenderer.spawnInstance`'s doc comment). `sourceNode`
    /// stays `nil` for these — there is no on-disk record yet to point at.
    var newInstanceObjectID: UInt16?
    var syntheticInstanceID: UInt32?
    /// "AI Pathfinding & Navmesh Editor" (roadmap 5.1): non-nil only for a
    /// waypoint added this session via `spawnAIWaypoint` — the raw
    /// `AIPosition.Num`/node-type value to encode on save, mirroring
    /// `newInstanceObjectID`'s role but for a distinct record type/layer
    /// (`.aiWaypoints`, not `.actors`), so `pendingLevelOverrides`'s
    /// `.actors`-only guard can't accidentally pick these up.
    var newAIWaypointRawNodeType: UInt16?
    var syntheticAIPositionID: UInt32?
    /// The real, on-disk `AIPosition.Num` value for an *existing* waypoint
    /// (`sourceNode != nil`) — preserved so a drag-save re-encodes with the
    /// waypoint's real node type instead of clobbering it with a default.
    /// `nil` for anything that isn't a real, loaded waypoint.
    var originalAIWaypointRawNodeType: UInt16?
    /// "Spline & Camera Path Persistence" (roadmap 6.3): non-nil only for a
    /// Camera Path/Spline control-point marker (not the camera's own box
    /// marker, which shares the `.cameras` layer but leaves this `nil`) —
    /// the control point's byte offset relative to the owning Camera
    /// record (`sourceNode`), captured at parse time
    /// (`CameraPath`/`CameraSpline.controlPointFileOffsets`). Lets
    /// `pendingCameraControlPointOverrides` patch a dragged point straight
    /// into the file at `sourceNode.fileOffset + this` without touching
    /// anything else in the variable-length Camera record.
    var cameraControlPointFileOffset: Int?
}

/// Which transform the gizmo currently edits — the W/E/R hotkeys switch
/// this, same as most 3D DCC tools' own convention.
enum GizmoMode: CaseIterable {
    case translate, rotate, scale
}

/// One gizmo axis (blueprint 6.1). `CaseIterable` order is also draw order
/// for the gizmo's three arrows/rings.
enum GizmoAxis: CaseIterable {
    case x, y, z

    var unitVector: SIMD3<Float> {
        switch self {
        case .x: return SIMD3(1, 0, 0)
        case .y: return SIMD3(0, 1, 0)
        case .z: return SIMD3(0, 0, 1)
        }
    }

    /// Matches the conventional red/green/blue axis-color scheme (also
    /// reused as-is by most 3D DCC tools' own gizmos), not anything
    /// Twinsanity-specific.
    var color: SIMD3<Float> {
        switch self {
        case .x: return SIMD3(0.95, 0.25, 0.25)
        case .y: return SIMD3(0.3, 0.9, 0.3)
        case .z: return SIMD3(0.3, 0.55, 0.95)
        }
    }

    /// Two unit vectors spanning the plane perpendicular to this axis —
    /// the plane a rotation ring around this axis actually lies in (e.g.
    /// the ring for rotating *around* X lies flat *in* the YZ plane).
    var planeBasis: (u: SIMD3<Float>, v: SIMD3<Float>) {
        switch self {
        case .x: return (SIMD3(0, 1, 0), SIMD3(0, 0, 1))
        case .y: return (SIMD3(1, 0, 0), SIMD3(0, 0, 1))
        case .z: return (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        }
    }
}

/// Shared by any renderer that draws a "Forge-style" transform gizmo on a
/// selected object and lets the user drag one of its handles — today just
/// `LevelViewerRenderer`. `InteractiveMTKView` checks for this conformance
/// to decide whether a `mouseDown` should try to grab a gizmo handle before
/// falling back to its normal orbit-drag behavior, and reads/writes
/// `gizmoMode` directly for the W/E/R hotkeys.
protocol GizmoInteractiveRenderer: OrbitCameraRenderer {
    var gizmoMode: GizmoMode { get set }
    /// Screen-space (AppKit view-point coordinates, `viewSize` = that same
    /// view's `bounds.size`) hit test against the current selection's
    /// gizmo handles for the current `gizmoMode`. `nil` if nothing is
    /// selected or the point isn't close enough to any handle.
    func gizmoAxis(at point: CGPoint, viewSize: CGSize) -> GizmoAxis?
    /// Applies `viewportDelta` (raw `NSEvent.deltaX`/`deltaY`, points) to
    /// the current selection along `axis`, interpreted per `gizmoMode`
    /// (move/rotate/scale), snapping to the configured grid if enabled.
    func dragSelectedObject(axis: GizmoAxis, viewportDelta: CGVector, viewSize: CGSize)
    /// "Click any rendered element to select it" (Level Editor overhaul):
    /// screen-space closest-point object pick, checked when a `mouseDown`
    /// didn't already grab a gizmo handle. Projects every currently-visible
    /// object's world position through the same view/projection matrix the
    /// frame was drawn with and returns the nearest one within a small
    /// pixel radius — not true ray/mesh intersection, but exact-shape
    /// picking would need per-object collision geometry this build doesn't
    /// have for placeholder markers anyway, and closest-projected-point is
    /// the same category of screen-space technique this file's gizmo hit
    /// test already uses. `nil` if nothing visible is close enough.
    func pickObject(at point: CGPoint, viewSize: CGSize) -> Int?
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

    // MARK: - Forge-style selection & gizmo (blueprint 6.1)

    private(set) var selectedObjectIndex: Int?
    var snapToGrid = true
    var gridSize: Float = 1.0
    /// Rotation snap step, in degrees — the rotate-mode equivalent of
    /// `gridSize`, gated by the same `snapToGrid` toggle.
    var rotationSnapDegrees: Float = 15.0
    var gizmoMode: GizmoMode = .translate { didSet { rebuildGizmoBuffer() } }
    private var gizmoBuffer: MTLBuffer?

    /// `boundsRadius`-relative, not a fixed world size — a gizmo sized for
    /// a small level would be invisible in a huge one and vice versa.
    private var gizmoArmLength: Float { max(boundsRadius * 0.12, 0.5) }

    /// "Level Editor Overhaul": every layer visible by default — the mode
    /// toggle/checkbox panel narrows this down, never the initial state.
    var layerVisibility: Set<SceneLayer> = Set(SceneLayer.allCases) {
        didSet { rebuildOverlayBuffer() }
    }
    /// "Scene Preview Mode" (roadmap 7.1): real `Trigger.id`s the camera is
    /// currently "inside" per `triggerContains` — see that function's doc
    /// comment. Empty (the default) when preview mode is off.
    var activeTriggerIDs: Set<UInt32> = [] {
        didSet { rebuildOverlayBuffer() }
    }
    private static let activeTriggerColor = SIMD3<Float>(1.0, 0.25, 0.15)
    private var overlayLineBuffer: MTLBuffer?
    private var overlayLineVertexCount = 0
    /// "Chunk-Based Architecture" (Part 2): the translucent fill for every
    /// visible boundary wall — separate from `overlayLineBuffer` because
    /// it draws as triangles through `translucentQuadPipelineState`, not
    /// lines through `collisionLineColoredPipelineState`.
    private var chunkWallTriangleBuffer: MTLBuffer?
    private var chunkWallTriangleVertexCount = 0

    /// - Parameters:
    ///   - placements: each resolved object's world position
    ///     (translation-only, see the type doc comment) paired with its
    ///     fully textured mesh.
    ///   - instanceMarkers: "Direct .RM2 Write-Back" — every `Instance`
    ///     record from the same file, drawn as a placeholder cube (see
    ///     `LevelViewerContext.instanceMarkers`'s doc comment for why not a
    ///     real mesh) but fully selectable/gizmo-editable/save-able like
    ///     any other object.
    ///   - triggers/cameras: "Level Editor Overhaul" — every `Trigger`/
    ///     `Camera` record from the same file. Both draw as an oriented
    ///     line wireframe box (`overlayLineBuffer`), not a solid mesh —
    ///     their real, decoded position/size/rotation, just no gizmo
    ///     write-back (unlike Instance markers, this build has no
    ///     byte-exact encoder for either record type yet). Still fully
    ///     selectable, so clicking one opens its real inspector.
    /// "The Forge Palette" (Part 4C): the same `GraphicsAssetIndex` used to
    /// resolve every existing `Instance`, kept around so a *newly placed*
    /// object (which has no `Instance` record to resolve from yet) can
    /// still get real geometry via `AssetResolver.resolveInstanceObject`
    /// instead of always falling back to the amber marker — a freshly
    /// dropped crate should look like a crate immediately, not just once
    /// the file round-trips through a save/reload.
    private var assetIndex: GraphicsAssetIndex = GraphicsAssetIndex()
    /// "No More Placeholder Squares": the same shared `Startup/Default.rm2`
    /// index `WorkspaceViewModel.resolvedInstanceAssets` already falls
    /// back to for existing Instance markers — kept here too so a
    /// *newly placed* shared object (e.g. dropping a `BASICCRATE` from
    /// the Forge Palette) also resolves to its real mesh immediately,
    /// not just after a save/reload round-trip through the level's own
    /// file. See `AssetResolver.resolveInstanceObject`'s doc comment for
    /// where this data actually comes from.
    private var defaultAssetIndex: GraphicsAssetIndex = GraphicsAssetIndex()
    /// Every synthetic ID handed out this session for a placed-but-unsaved
    /// object, one higher than the highest real `Instance.id` seen at
    /// upload time — see `spawnInstance`'s doc comment.
    private var nextSyntheticInstanceID: UInt32 = 1
    /// "Unrestricted Chunk Free-Edit Mode": real `Instance.objectID`,
    /// keyed by that instance's `ChunkNode.id` — populated once at
    /// `upload()` time, read by `duplicateSelectedObject` so it can spawn
    /// a copy of an *existing* placement without threading the full
    /// `PlacedInstance` through `GPULevelObject` just for this one use.
    private var instanceObjectIDByNodeID: [UUID: UInt16] = [:]
    /// Same idea as `nextSyntheticInstanceID`, for waypoints added this
    /// session via `spawnAIWaypoint` — a separate counter/namespace since
    /// `AIPosition` and `Instance` record IDs are independent (see
    /// `ResolvedModelAsset.id`'s own doc comment for the same "these are
    /// different on-disk ID spaces" reasoning).
    private var nextSyntheticAIPositionID: UInt32 = 1

    init?(
        placements: [(worldPosition: SIMD3<Float>, asset: ResolvedModelAsset)],
        instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)] = [],
        resolvedInstanceAssets: [UUID: ResolvedModelAsset] = [:],
        assetIndex: GraphicsAssetIndex = GraphicsAssetIndex(),
        defaultAssetIndex: GraphicsAssetIndex = GraphicsAssetIndex(),
        triggers: [(node: ChunkNode, trigger: TriggerVolume)] = [],
        cameras: [(node: ChunkNode, camera: PlacedCamera)] = [],
        chunkLinks: [(node: ChunkNode, link: ChunkLink)] = [],
        aiPositions: [(node: ChunkNode, marker: AIPositionMarker)] = []
    ) {
        guard let context = ModelViewerGPUContext.shared else { return nil }
        self.context = context
        self.assetIndex = assetIndex
        self.defaultAssetIndex = defaultAssetIndex
        super.init()
        nextSyntheticInstanceID = (instanceMarkers.map(\.instance.id).max() ?? 0) + 1
        nextSyntheticAIPositionID = (aiPositions.map(\.marker.id).max() ?? 0) + 1
        upload(placements: placements, instanceMarkers: instanceMarkers, resolvedInstanceAssets: resolvedInstanceAssets, triggers: triggers, cameras: cameras, chunkLinks: chunkLinks, aiPositions: aiPositions)
    }

    private func upload(
        placements: [(worldPosition: SIMD3<Float>, asset: ResolvedModelAsset)],
        instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)],
        resolvedInstanceAssets: [UUID: ResolvedModelAsset],
        triggers: [(node: ChunkNode, trigger: TriggerVolume)],
        cameras: [(node: ChunkNode, camera: PlacedCamera)],
        chunkLinks: [(node: ChunkNode, link: ChunkLink)],
        aiPositions: [(node: ChunkNode, marker: AIPositionMarker)]
    ) {
        var minBound = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var levelObjects: [GPULevelObject] = []
        levelObjects.reserveCapacity(placements.count + instanceMarkers.count + triggers.count + cameras.count)
        // "Massive level rendering" (performance mandate): one texture
        // cache shared across every placement built in this single
        // upload() call — see TextureUploadCache's own doc comment for why
        // this is scoped per-file/per-call rather than a persistent
        // cross-file cache.
        let textureCache = TextureUploadCache()

        func expandBounds(_ p: SIMD3<Float>) {
            minBound = simd_min(minBound, p)
            maxBound = simd_max(maxBound, p)
        }

        for (worldPosition, asset) in placements {
            let built = ModelViewerRenderer.buildGPUSubmeshes(mesh: asset.mesh, submeshMaterials: asset.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture, textureCache: textureCache)
            guard !built.submeshes.isEmpty else { continue }
            levelObjects.append(GPULevelObject(worldPosition: worldPosition, displayName: asset.displayName, submeshes: built.submeshes, layer: .scenery, boundingRadius: Self.boundingRadius(of: asset.mesh)))
            // Bounds are tracked from placement position, not local mesh
            // extent — for a whole-level view, "where objects are" matters
            // far more than any one object's own size.
            expandBounds(worldPosition)
        }

        let markerMesh = Self.makeMarkerCubeAsset()
        let markerBuilt = ModelViewerRenderer.buildGPUSubmeshes(mesh: markerMesh.mesh, submeshMaterials: [markerMesh.material], device: device, fallbackTexture: context.fallbackTexture, textureCache: textureCache)
        let markerRadius = Self.boundingRadius(of: markerMesh.mesh)
        for (node, instance) in instanceMarkers {
            // "Unrestricted Chunk Free-Edit Mode": remembered so
            // `duplicateSelectedObject` can look up a real, existing
            // Instance's own objectID by its node identity, without
            // needing to thread `PlacedInstance` itself through
            // `GPULevelObject` just for this one use.
            instanceObjectIDByNodeID[node.id] = instance.objectID
            let worldPosition = SIMD3(instance.position.x, instance.position.y, instance.position.z)
            // "Comprehensive Instance Population" (Part 4B): real geometry
            // when this build could resolve one (GameObject -> GraphicsInfo
            // -> skinned mesh or rigid model-link parts), the amber
            // placeholder cube otherwise — never a fabricated stand-in.
            var submeshes = markerBuilt.submeshes
            var boundingRadius = markerRadius
            if let resolvedAsset = resolvedInstanceAssets[node.id] {
                let built = ModelViewerRenderer.buildGPUSubmeshes(mesh: resolvedAsset.mesh, submeshMaterials: resolvedAsset.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture, textureCache: textureCache)
                if !built.submeshes.isEmpty {
                    submeshes = built.submeshes
                    boundingRadius = Self.boundingRadius(of: resolvedAsset.mesh)
                }
            }
            guard !submeshes.isEmpty else { continue }
            levelObjects.append(GPULevelObject(
                worldPosition: worldPosition,
                rotation: Self.quaternion(fromEulerDegrees: instance.rotationDegrees),
                displayName: "Instance #\(instance.id) (Object \(instance.objectID))",
                submeshes: submeshes,
                layer: .actors,
                boundingRadius: boundingRadius,
                sourceNode: node,
                originalPositionW: instance.position.w,
                comRotationRaw: instance.comRotationRaw
            ))
            expandBounds(worldPosition)
        }

        for (node, trigger) in triggers {
            let worldPosition = SIMD3(trigger.position.x, trigger.position.y, trigger.position.z)
            levelObjects.append(GPULevelObject(
                worldPosition: worldPosition,
                rotation: simd_quatf(vector: trigger.rotationQuaternion),
                displayName: "Trigger #\(trigger.id)",
                submeshes: [],
                layer: .triggers,
                sourceNode: node
            ))
            expandBounds(worldPosition)
        }

        for (node, camera) in cameras {
            let worldPosition = SIMD3(camera.position.x, camera.position.y, camera.position.z)
            levelObjects.append(GPULevelObject(
                worldPosition: worldPosition,
                rotation: simd_quatf(vector: camera.rotationQuaternion),
                displayName: "Camera #\(camera.id) (\(camera.cameraType1.displayName))",
                submeshes: [],
                layer: .cameras,
                sourceNode: node
            ))
            expandBounds(worldPosition)
            // "Spline & Camera Path Persistence" (roadmap 6.3): each real
            // control point gets its own selectable, draggable marker, and
            // — where its exact on-disk offset was captured at parse time
            // (`cameraControlPointFileOffset`) — a real save path: dragging
            // it and saving patches just that point's 16 bytes at
            // `node.fileOffset + cameraControlPointFileOffset`, leaving the
            // rest of this variable-length Camera record untouched (see
            // `pendingCameraControlPointOverrides`). `sourceNode` is the
            // *camera's* node (a control point isn't a record of its own),
            // matching how `originalAIWaypointRawNodeType` etc. key off
            // their owning record.
            for (pointIndex, point) in Self.splineControlPoints(for: camera).enumerated() {
                let pointPosition = SIMD3(point.vector.x, point.vector.y, point.vector.z)
                levelObjects.append(GPULevelObject(
                    worldPosition: pointPosition,
                    displayName: "Camera #\(camera.id) control point \(pointIndex)",
                    submeshes: [],
                    layer: .cameras,
                    sourceNode: point.fileOffset != nil ? node : nil,
                    originalPositionW: point.vector.w,
                    cameraControlPointFileOffset: point.fileOffset
                ))
                expandBounds(pointPosition)
            }
        }

        // "Chunk-Based Architecture" (Part 2): a selectable marker at each
        // real boundary wall's centroid, same treatment as trigger/camera
        // markers above — the wall's actual quad geometry draws separately
        // via `rebuildOverlayBuffer`'s translucent-plane pass.
        for (node, link) in chunkLinks {
            guard let wall = link.loadWall, !wall.isEmpty else { continue }
            let centroid = wall.reduce(SIMD3<Float>.zero) { $0 + SIMD3($1.x, $1.y, $1.z) } / Float(wall.count)
            levelObjects.append(GPULevelObject(
                worldPosition: centroid,
                displayName: "Chunk Link #\(link.id): \(link.path)",
                submeshes: [],
                layer: .chunkBoundaries,
                sourceNode: node
            ))
            expandBounds(centroid)
        }

        // "AI Pathfinding/Navmesh Editor" (roadmap 5.1): a selectable,
        // draggable marker per real `AIPosition` waypoint — same treatment
        // as trigger/camera markers (empty submeshes, drawn as a small
        // wireframe box by `rebuildOverlayBuffer`). Draggable via the same
        // generic gizmo every other object uses, but session-only: this
        // layer is deliberately excluded from `pendingLevelOverrides`
        // (`.actors`-only guard), since this build has no verified
        // byte-exact `AIPosition` encoder to write a moved waypoint back.
        for (node, marker) in aiPositions {
            let worldPosition = SIMD3(marker.position.x, marker.position.y, marker.position.z)
            levelObjects.append(GPULevelObject(
                worldPosition: worldPosition,
                displayName: "AI Waypoint #\(marker.id) (\(marker.nodeType?.displayName ?? "type \(marker.rawNodeType)"))",
                submeshes: [],
                layer: .aiWaypoints,
                sourceNode: node,
                originalPositionW: marker.position.w,
                originalAIWaypointRawNodeType: marker.rawNodeType
            ))
            expandBounds(worldPosition)
        }

        objects = levelObjects
        self.triggers = triggers
        self.cameras = cameras
        self.chunkLinks = chunkLinks
        self.aiPositions = aiPositions
        if minBound.x <= maxBound.x {
            boundsCenter = (minBound + maxBound) / 2
            let extent = maxBound - minBound
            boundsRadius = max(max(extent.x, extent.y), max(extent.z, 10))
        }
        rebuildOverlayBuffer()
    }

    /// Kept alongside `objects` purely to rebuild `overlayLineBuffer` when
    /// layer visibility toggles — the wireframes themselves aren't part of
    /// the indexed-triangle `objects` draw path (see `GPULevelObject.
    /// submeshes`'s doc comment), so they need their own source data to
    /// redraw from.
    private var triggers: [(node: ChunkNode, trigger: TriggerVolume)] = []
    private var cameras: [(node: ChunkNode, camera: PlacedCamera)] = []
    /// "Chunk-Based Architecture" (Part 2): every real `ChunkLink` in the
    /// currently loaded chunk, kept alongside `objects` for the same reason
    /// `triggers`/`cameras` are — `rebuildOverlayBuffer` needs the raw
    /// source data to redraw wall wireframes/fills when the layer toggles.
    private(set) var chunkLinks: [(node: ChunkNode, link: ChunkLink)] = []
    /// "AI Pathfinding/Navmesh Editor" (roadmap 5.1): every real
    /// `AIPosition` waypoint in the currently loaded chunk — same
    /// `rebuildOverlayBuffer` reasoning as `triggers`/`cameras` above.
    private(set) var aiPositions: [(node: ChunkNode, marker: AIPositionMarker)] = []

    /// Control points for whichever of a camera's two sub-payload slots
    /// actually has spline/path data — `nil`-safe: most cameras have
    /// neither, in which case this returns an empty path and only the
    /// camera's own box marker draws. Paired with each point's real
    /// record-relative file offset (`nil` only if `controlPointFileOffsets`
    /// somehow came up short of `unkVectors`, which parsing never actually
    /// produces — defensive, not expected) so a dragged point can be
    /// patched back to its exact byte offset on save.
    private static func splineControlPoints(for camera: PlacedCamera) -> [(vector: SIMD4<Float>, fileOffset: Int?)] {
        for subtype in [camera.subtype1, camera.subtype2] {
            switch subtype {
            case .spline(let spline):
                return spline.unkVectors.enumerated().map { index, v in (v, spline.controlPointFileOffsets.indices.contains(index) ? spline.controlPointFileOffsets[index] : nil) }
            case .path(let path):
                return path.unkVectors.enumerated().map { index, v in (v, path.controlPointFileOffsets.indices.contains(index) ? path.controlPointFileOffsets[index] : nil) }
            default: continue
            }
        }
        return []
    }

    /// "Scene Preview Mode" (roadmap 7.1) — real oriented-box containment:
    /// `point` transformed into the trigger's own local space (undo its
    /// real decoded rotation, then its real decoded position), tested
    /// against its real decoded half-extents. The same oriented box
    /// `appendBox` already draws as this trigger's wireframe — this just
    /// asks "is this point inside the box actually being drawn," nothing
    /// about trigger *semantics* (this format has no decoded "on enter"
    /// callback this build could hook into either way).
    static func triggerContains(_ trigger: TriggerVolume, point: SIMD3<Float>) -> Bool {
        let position = SIMD3(trigger.position.x, trigger.position.y, trigger.position.z)
        let rotation = simd_quatf(vector: trigger.rotationQuaternion)
        let localPoint = rotation.inverse.act(point - position)
        let halfExtents = SIMD3(max(trigger.size.x, 0.1), max(trigger.size.y, 0.1), max(trigger.size.z, 0.1)) / 2
        return abs(localPoint.x) <= halfExtents.x && abs(localPoint.y) <= halfExtents.y && abs(localPoint.z) <= halfExtents.z
    }

    /// Recomputes `activeTriggerIDs` from `cameraEyeWorldPosition` against
    /// every real trigger — call this periodically while "Scene Preview
    /// Mode" is on (`LevelViewerWindow` drives this from a timer, the same
    /// pattern the Animation Sandbox's own playback timer already uses).
    func updateActiveTriggers() {
        let eye = cameraEyeWorldPosition
        activeTriggerIDs = Set(triggers.compactMap { Self.triggerContains($0.trigger, point: eye) ? $0.trigger.id : nil })
    }

    /// Rebuilds the line-primitive vertex buffer for trigger/camera
    /// wireframe boxes plus camera spline paths — everything in
    /// `overlayLineBuffer`, drawn through the same `collisionLineColoredPipelineState`
    /// the gizmo already uses (`LineVertexColorIn`: interleaved position +
    /// color). Skipped entirely for a hidden layer, both to save the (tiny)
    /// rebuild cost and so a hidden trigger/camera can't still be picked
    /// via `pickObject`, which only scans `objects` — layer-gating that
    /// list is `pickObject`'s job, this buffer is purely visual.
    private func rebuildOverlayBuffer() {
        var floats: [Float] = []
        func appendVertex(_ position: SIMD3<Float>, _ color: SIMD3<Float>) {
            floats.append(contentsOf: [position.x, position.y, position.z, color.x, color.y, color.z])
        }
        func appendBox(position: SIMD3<Float>, size: SIMD3<Float>, rotation: simd_quatf, color: SIMD3<Float>) {
            let half = size / 2
            let localCorners: [SIMD3<Float>] = [
                SIMD3(-half.x, -half.y, -half.z), SIMD3(half.x, -half.y, -half.z),
                SIMD3(half.x, half.y, -half.z), SIMD3(-half.x, half.y, -half.z),
                SIMD3(-half.x, -half.y, half.z), SIMD3(half.x, -half.y, half.z),
                SIMD3(half.x, half.y, half.z), SIMD3(-half.x, half.y, half.z)
            ]
            let corners = localCorners.map { position + rotation.act($0) }
            let edges: [(Int, Int)] = [
                (0, 1), (1, 2), (2, 3), (3, 0),
                (4, 5), (5, 6), (6, 7), (7, 4),
                (0, 4), (1, 5), (2, 6), (3, 7)
            ]
            for (a, b) in edges {
                appendVertex(corners[a], color)
                appendVertex(corners[b], color)
            }
        }

        // Roadmap 4.1 asks for a 3-color Red=Death/Green=Trigger/Blue=Solid
        // scheme. Green is real: every wireframe box here genuinely *is* a
        // `Trigger` record — a verified category, not a guess. Splitting
        // further into "death" vs. other triggers is not: `TriggerVolume`'s
        // `arg1`-`arg4`/`enabledMask`/`header` carry no decoded meaning
        // anywhere in this codebase (see `ModelViewerRenderer.color(forSurfaceID:)`'s
        // own doc comment for the identical situation with collision
        // surface IDs) — inventing a "this bit pattern means deadly" rule
        // would be presenting a guess as decoded data. "Solid" isn't a
        // trigger-layer concept at all; that's what the Collision layer's
        // own (already real, already surface-ID-based) coloring covers.
        let triggerColor = SIMD3<Float>(0.35, 0.9, 0.4)
        let cameraColor = SIMD3<Float>(0.3, 0.85, 0.95)
        let splineColor = SIMD3<Float>(0.85, 0.35, 0.95)

        if layerVisibility.contains(.triggers) {
            for (_, trigger) in triggers {
                let position = SIMD3(trigger.position.x, trigger.position.y, trigger.position.z)
                let size = SIMD3(max(trigger.size.x, 0.1), max(trigger.size.y, 0.1), max(trigger.size.z, 0.1))
                // "Scene Preview Mode" (roadmap 7.1): a real, live geometric
                // containment test — see `cameraEyeWorldPosition`'s doc
                // comment for the "orbit camera as proxy" honesty note —
                // against this trigger's real decoded oriented box, not a
                // fabricated "the player touched this" event.
                let color = activeTriggerIDs.contains(trigger.id) ? Self.activeTriggerColor : triggerColor
                appendBox(position: position, size: size, rotation: simd_quatf(vector: trigger.rotationQuaternion), color: color)
            }
        }
        if layerVisibility.contains(.cameras) {
            for (_, camera) in cameras {
                let position = SIMD3(camera.position.x, camera.position.y, camera.position.z)
                let size = SIMD3(max(camera.size.x, 0.1), max(camera.size.y, 0.1), max(camera.size.z, 0.1))
                appendBox(position: position, size: size, rotation: simd_quatf(vector: camera.rotationQuaternion), color: cameraColor)
                let controlPoints = Self.splineControlPoints(for: camera).map { SIMD3($0.vector.x, $0.vector.y, $0.vector.z) }
                // "Interactive Spline & Camera Path Visualizer" (roadmap
                // 6.3): a small marker box at every real control point,
                // not just the connecting polyline — this is what actually
                // makes each point visually distinguishable and clickable
                // (`pickObject` targets `objects`, which now has one entry
                // per control point too, added alongside this in `upload`).
                for point in controlPoints {
                    appendBox(position: point, size: SIMD3(repeating: 0.3), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), color: splineColor)
                }
                guard controlPoints.count >= 2 else { continue }
                for i in 0..<(controlPoints.count - 1) {
                    appendVertex(controlPoints[i], splineColor)
                    appendVertex(controlPoints[i + 1], splineColor)
                }
            }
        }

        // "AI Pathfinding/Navmesh Editor" (roadmap 5.1): a small fixed-size
        // wireframe box per real `AIPosition` waypoint — `AIPosition` has
        // no size/rotation of its own (just a point + the `Num`/node-type
        // field), so unlike trigger/camera boxes this one's a fixed visual
        // marker, not decoded extent.
        let aiWaypointColor = SIMD3<Float>(0.4, 0.9, 0.65)
        if layerVisibility.contains(.aiWaypoints) {
            for (_, marker) in aiPositions {
                let position = SIMD3(marker.position.x, marker.position.y, marker.position.z)
                appendBox(position: position, size: SIMD3(repeating: 0.35), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), color: aiWaypointColor)
            }
        }

        // "Chunk-Based Architecture" (Part 2): the real "load wall" quad
        // from each `ChunkLink` that has one — an outline here (for
        // visibility from any angle, including edge-on) plus a filled
        // translucent quad below (`chunkWallTriangleBuffer`) for the
        // "translucent plane" the mandate asks for.
        let wallColor = SIMD3<Float>(0.95, 0.75, 0.2)
        var wallFloats: [Float] = []
        func appendWallVertex(_ position: SIMD3<Float>, _ color: SIMD3<Float>) {
            wallFloats.append(contentsOf: [position.x, position.y, position.z, color.x, color.y, color.z])
        }
        if layerVisibility.contains(.chunkBoundaries) {
            for (_, link) in chunkLinks {
                guard let wall = link.loadWall, wall.count == 4 else { continue }
                let corners = wall.map { SIMD3($0.x, $0.y, $0.z) }
                appendVertex(corners[0], wallColor); appendVertex(corners[1], wallColor)
                appendVertex(corners[1], wallColor); appendVertex(corners[2], wallColor)
                appendVertex(corners[2], wallColor); appendVertex(corners[3], wallColor)
                appendVertex(corners[3], wallColor); appendVertex(corners[0], wallColor)
                // Two triangles (0,1,2) and (0,2,3) covering the quad —
                // corner winding/order is exactly as decoded, unconfirmed
                // against a real renderer, so both faces draw (see the
                // `.none` cull mode set around this buffer's draw call).
                appendWallVertex(corners[0], wallColor); appendWallVertex(corners[1], wallColor); appendWallVertex(corners[2], wallColor)
                appendWallVertex(corners[0], wallColor); appendWallVertex(corners[2], wallColor); appendWallVertex(corners[3], wallColor)
            }
        }

        if wallFloats.isEmpty {
            chunkWallTriangleBuffer = nil
            chunkWallTriangleVertexCount = 0
        } else {
            chunkWallTriangleVertexCount = wallFloats.count / 6
            chunkWallTriangleBuffer = device.makeBuffer(bytes: wallFloats, length: wallFloats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
        }

        guard !floats.isEmpty else {
            overlayLineBuffer = nil
            overlayLineVertexCount = 0
            return
        }
        overlayLineVertexCount = floats.count / 6
        overlayLineBuffer = device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    /// A small procedural cube (0.8 world units per side) plus a solid
    /// amber texture, standing in for an `Instance` record's real geometry
    /// (see `LevelViewerContext.instanceMarkers`'s doc comment for why: no
    /// verified `objectID` -> mesh mapping exists in this build). Built as
    /// 12 independent triangles, not a shared-vertex indexed cube — the
    /// `MeshSubmesh.connectivity`/`triangleIndices()` triangle-strip scheme
    /// this pipeline's mesh format uses reads a sliding window of 3
    /// consecutive vertices per candidate triangle, so restarting the strip
    /// after every triangle (`connectivity = [false, false, true]` per
    /// triple) is what turns it into 12 disconnected triangles instead of a
    /// connected strip. `addTriangle`'s odd/even vertex swap exists purely
    /// to counteract `triangleIndices()`'s own alternating-winding rule for
    /// strips (`ModelViewerRenderer.swift`'s `MeshSubmesh.triangleIndices`
    /// doc comment) — without it, every other face here would be wound
    /// backwards and get backface-culled.
    private static func makeMarkerCubeAsset() -> (mesh: MeshAsset, material: ResolvedSubmeshMaterial) {
        let half: Float = 0.4
        var vertices: [StaticVertex] = []
        var connectivity: [Bool] = []

        func addTriangle(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, normal: SIMD3<Float>) {
            let i = vertices.count
            let odd = (i & 1) == 1
            let ordered: [SIMD3<Float>] = odd ? [p1, p0, p2] : [p0, p1, p2]
            for p in ordered {
                vertices.append(StaticVertex(position: p, normal: normal, uv: SIMD2(0.5, 0.5)))
            }
            connectivity.append(false)
            connectivity.append(false)
            connectivity.append(true)
        }

        let c: [SIMD3<Float>] = [
            SIMD3(-half, -half, -half), SIMD3(half, -half, -half), SIMD3(half, half, -half), SIMD3(-half, half, -half),
            SIMD3(-half, -half, half), SIMD3(half, -half, half), SIMD3(half, half, half), SIMD3(-half, half, half)
        ]
        let faces: [(a: Int, b: Int, c: Int, d: Int, normal: SIMD3<Float>)] = [
            (0, 1, 2, 3, SIMD3(0, 0, -1)),
            (5, 4, 7, 6, SIMD3(0, 0, 1)),
            (4, 0, 3, 7, SIMD3(-1, 0, 0)),
            (1, 5, 6, 2, SIMD3(1, 0, 0)),
            (3, 2, 6, 7, SIMD3(0, 1, 0)),
            (4, 5, 1, 0, SIMD3(0, -1, 0))
        ]
        for face in faces {
            addTriangle(c[face.a], c[face.b], c[face.c], normal: face.normal)
            addTriangle(c[face.a], c[face.c], c[face.d], normal: face.normal)
        }

        let submesh = MeshSubmesh(vertices: vertices, connectivity: connectivity)
        let mesh = MeshAsset(id: 0, isSkinned: false, submeshes: [submesh])
        let texture = TextureAsset(id: 0, width: 1, height: 1, pixelFormat: .rawRGBA, rgba: [255, 149, 0, 255])
        return (mesh, ResolvedSubmeshMaterial(texture: texture))
    }

    /// "Save Level Overrides": the current position/rotation of every
    /// Instance marker, re-encoded and paired with the `ChunkNode` it
    /// patches into — ready to hand straight to `WorkspaceViewModel.
    /// patchedFileBytes(applyingPrefixPatches:)`. Includes every marker,
    /// not just ones that moved: writing an unchanged transform back is a
    /// harmless no-op patch, and skipping "unchanged" ones would need exact
    /// float-equality tracking against the original decode for no real
    /// benefit.
    var pendingLevelOverrides: [(node: ChunkNode, encoded: Data)] {
        objects.compactMap { object in
            // `.actors` only: triggers/cameras also carry a `sourceNode`
            // (for click-to-inspect), but `writeInstanceTransform` encodes
            // an `Instance` record's byte layout specifically — applying it
            // to a Trigger/Camera node would silently corrupt that record.
            guard object.layer == .actors, let node = object.sourceNode else { return nil }
            let degrees = Self.eulerDegrees(from: object.rotation)
            let rotationRaw = SIMD3(
                PlacedInstance.rawAngle(fromDegrees: degrees.x),
                PlacedInstance.rawAngle(fromDegrees: degrees.y),
                PlacedInstance.rawAngle(fromDegrees: degrees.z)
            )
            let position = SIMD4(object.worldPosition.x, object.worldPosition.y, object.worldPosition.z, object.originalPositionW)
            let encoded = WorldPlacementWriter.writeInstanceTransform(position: position, rotationRaw: rotationRaw, comRotationRaw: object.comRotationRaw)
            return (node, encoded)
        }
    }

    var hasGeometry: Bool { !objects.isEmpty }
    var objectCount: Int { objects.count }

    /// Backs the Level Viewer sidebar's object list and the coordinate
    /// nudge fields — index-paired with the internal `objects` array so
    /// `select(index:)`/`setSelectedPosition(to:)` can address the same
    /// entries directly.
    var objectSummaries: [(index: Int, displayName: String, worldPosition: SIMD3<Float>)] {
        objects.enumerated().map { ($0.offset, $0.element.displayName, $0.element.worldPosition) }
    }

    var selectedPosition: SIMD3<Float>? {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return nil }
        return objects[selectedObjectIndex].worldPosition
    }

    /// Euler-angle degrees, decomposed from the object's quaternion in
    /// XYZ order — quaternions are what actually drive the model matrix
    /// (composable, no gimbal-lock surprises mid-drag), but Euler degrees
    /// are what a nudge-field UI should show; nobody edits a rotation by
    /// typing quaternion components directly.
    var selectedRotationDegrees: SIMD3<Float>? {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return nil }
        return Self.eulerDegrees(from: objects[selectedObjectIndex].rotation)
    }

    var selectedScale: SIMD3<Float>? {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return nil }
        return objects[selectedObjectIndex].scale
    }

    /// "Level Editor Overhaul": the `ChunkNode` behind whatever's currently
    /// selected — `nil` for scenery placements and Models-Hub-dropped
    /// props (neither has one), non-`nil` for Instance/Trigger/Camera
    /// markers. Lets the SwiftUI side route to the right real inspector
    /// (`node.payload` already carries which kind it is) without this
    /// renderer needing to know anything about SwiftUI views.
    var selectedSourceNode: ChunkNode? {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return nil }
        return objects[selectedObjectIndex].sourceNode
    }

    func select(index: Int?) {
        selectedObjectIndex = index.flatMap { objects.indices.contains($0) ? $0 : nil }
        rebuildGizmoBuffer()
    }

    /// "Level Events" panel: selects whichever object was built from
    /// `node` (identity, not value, comparison — `ChunkNode` is a
    /// reference type) so clicking an event row both highlights it in the
    /// sidebar and (via `orbitTarget` already following the selection)
    /// snaps the camera to it. Returns whether a match was found — `node`
    /// could in principle belong to a layer that's currently hidden and
    /// therefore still present in `objects` but intentionally not
    /// selectable via viewport picking; selecting it programmatically from
    /// the events list is fine either way.
    @discardableResult
    func selectByNode(_ node: ChunkNode) -> Bool {
        guard let index = objects.firstIndex(where: { $0.sourceNode === node }) else { return false }
        select(index: index)
        return true
    }

    /// Direct position edit — the sidebar's X/Y/Z nudge fields go through
    /// this, same as a gizmo drag does at the end of `dragSelectedObject`.
    func setSelectedPosition(to newPosition: SIMD3<Float>) {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return }
        objects[selectedObjectIndex].worldPosition = newPosition
        rebuildGizmoBuffer()
    }

    func setSelectedRotation(eulerDegrees: SIMD3<Float>) {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return }
        objects[selectedObjectIndex].rotation = Self.quaternion(fromEulerDegrees: eulerDegrees)
        rebuildGizmoBuffer()
    }

    func setSelectedScale(to newScale: SIMD3<Float>) {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return }
        // A zero or negative scale collapses/flips the mesh in a way
        // that's indistinguishable from "the model disappeared" — the
        // exact class of bug the earlier blank-viewport investigation
        // spent a long time chasing, so this is guarded explicitly rather
        // than trusting every caller (nudge-field typos included) to
        // avoid it.
        let clamped = SIMD3(max(newScale.x, 0.01), max(newScale.y, 0.01), max(newScale.z, 0.01))
        objects[selectedObjectIndex].scale = clamped
        rebuildGizmoBuffer()
    }

    private static func eulerDegrees(from quaternion: simd_quatf) -> SIMD3<Float> {
        let m = simd_float3x3(quaternion)
        let sy = sqrt(m.columns.0.x * m.columns.0.x + m.columns.0.y * m.columns.0.y)
        let singular = sy < 1e-6
        let x: Float, y: Float, z: Float
        if !singular {
            x = atan2(m.columns.1.z, m.columns.2.z)
            y = atan2(-m.columns.0.z, sy)
            z = atan2(m.columns.0.y, m.columns.0.x)
        } else {
            x = atan2(-m.columns.2.y, m.columns.1.y)
            y = atan2(-m.columns.0.z, sy)
            z = 0
        }
        let toDegrees: Float = 180 / .pi
        return SIMD3(x * toDegrees, y * toDegrees, z * toDegrees)
    }

    /// The radius of the smallest sphere centered on the object's own local
    /// origin that contains every vertex — rotation-invariant (distance
    /// from origin doesn't change under rotation), so this is computed once
    /// at upload time and reused as-is at every orientation. "Seamless
    /// Full-Map Rendering" (Part 1): feeds the frustum cull's per-object
    /// sphere test.
    private static func boundingRadius(of mesh: MeshAsset) -> Float {
        var maxDistanceSquared: Float = 0
        for submesh in mesh.submeshes {
            for vertex in submesh.vertices {
                maxDistanceSquared = max(maxDistanceSquared, simd_length_squared(vertex.position))
            }
        }
        return max(sqrt(maxDistanceSquared), 0.01)
    }

    private static func quaternion(fromEulerDegrees degrees: SIMD3<Float>) -> simd_quatf {
        let toRadians: Float = .pi / 180
        let r = degrees * toRadians
        let qx = simd_quatf(angle: r.x, axis: SIMD3(1, 0, 0))
        let qy = simd_quatf(angle: r.y, axis: SIMD3(0, 1, 0))
        let qz = simd_quatf(angle: r.z, axis: SIMD3(0, 0, 1))
        return qz * qy * qx
    }

    /// "Drag-and-Drop Asset Palette" (blueprint 6.2): appends a new
    /// in-session placement at `boundsCenter` (the level's own visual
    /// center — as good a default drop point as any without a real 3D
    /// cursor/raycast-to-ground target) and selects it immediately so its
    /// gizmo is ready to drag into place. Deliberately does **not**
    /// recompute `boundsCenter`/`boundsRadius`/the camera framing — that
    /// would jump the camera every time an object is added, which reads as
    /// the viewport "jumping" rather than as a natural drop.
    @discardableResult
    func addObject(asset: ResolvedModelAsset) -> Int? {
        let built = ModelViewerRenderer.buildGPUSubmeshes(mesh: asset.mesh, submeshMaterials: asset.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture)
        guard !built.submeshes.isEmpty else { return nil }
        objects.append(GPULevelObject(worldPosition: boundsCenter, displayName: asset.displayName, submeshes: built.submeshes, layer: .actors, boundingRadius: Self.boundingRadius(of: asset.mesh)))
        let newIndex = objects.count - 1
        select(index: newIndex)
        return newIndex
    }

    /// "Chunk-Based Architecture" (Part 2): appends a neighboring chunk's
    /// already-resolved scenery placements — offset by `worldOffset` (the
    /// requesting `ChunkLink.chunkMatrix`'s translation row, see
    /// `WorkspaceViewModel.loadChunkLinkPlacements`'s doc comment for why
    /// only translation, not the full matrix, is applied) — into this same
    /// viewport as a distinct, independently toggleable `.linkedChunks`
    /// layer. Same "don't recenter the camera" convention as `addObject`:
    /// loading a neighbor in for context shouldn't yank the view away from
    /// what the user was already looking at.
    func stitchChunk(placements: [(worldPosition: SIMD3<Float>, asset: ResolvedModelAsset)], worldOffset: SIMD3<Float>) -> Int {
        var added = 0
        for (worldPosition, asset) in placements {
            let built = ModelViewerRenderer.buildGPUSubmeshes(mesh: asset.mesh, submeshMaterials: asset.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture)
            guard !built.submeshes.isEmpty else { continue }
            objects.append(GPULevelObject(
                worldPosition: worldPosition + worldOffset,
                displayName: asset.displayName,
                submeshes: built.submeshes,
                layer: .linkedChunks,
                boundingRadius: Self.boundingRadius(of: asset.mesh)
            ))
            added += 1
        }
        return added
    }

    /// "Cross-Engine Chunk Stitcher" (roadmap 5.3): plots real *Wrath of
    /// Cortex* crate/wumpa positions — a genuinely different TT-engine
    /// game's data, see `WOCCrateFile`'s doc comment for the "ported, not
    /// verified against real WoC bytes" caveat — as small colored wireframe
    /// markers in this same viewport, `worldOffset` letting the caller
    /// place them next to (not on top of) the currently loaded Twinsanity
    /// chunk. No `sourceNode` (these don't come from an `.RM2`/`.SM2` tree
    /// at all), so they're visible/toggleable but not click-to-inspect.
    func stitchCrossEngineData(crates: [SIMD3<Float>], wumpas: [SIMD3<Float>], worldOffset: SIMD3<Float>) {
        for position in crates {
            objects.append(GPULevelObject(worldPosition: position + worldOffset, displayName: "WoC Crate", submeshes: [], layer: .crossEngine))
        }
        for position in wumpas {
            objects.append(GPULevelObject(worldPosition: position + worldOffset, displayName: "WoC Wumpa", submeshes: [], layer: .crossEngine))
        }
        crossEngineMarkerPositions.append(contentsOf: crates.map { ($0 + worldOffset, Self.woCCrateColor) })
        crossEngineMarkerPositions.append(contentsOf: wumpas.map { ($0 + worldOffset, Self.woCWumpaColor) })
        rebuildCrossEngineBuffer()
    }

    private static let woCCrateColor = SIMD3<Float>(0.95, 0.45, 0.15)
    private static let woCWumpaColor = SIMD3<Float>(0.95, 0.85, 0.2)
    private var crossEngineMarkerPositions: [(SIMD3<Float>, SIMD3<Float>)] = []
    private var crossEngineLineBuffer: MTLBuffer?
    private var crossEngineLineVertexCount = 0

    private func rebuildCrossEngineBuffer() {
        var floats: [Float] = []
        func appendVertex(_ position: SIMD3<Float>, _ color: SIMD3<Float>) {
            floats.append(contentsOf: [position.x, position.y, position.z, color.x, color.y, color.z])
        }
        for (position, color) in crossEngineMarkerPositions {
            let half: Float = 0.25
            let corners: [SIMD3<Float>] = [
                position + SIMD3(-half, -half, -half), position + SIMD3(half, -half, -half),
                position + SIMD3(half, half, -half), position + SIMD3(-half, half, -half),
                position + SIMD3(-half, -half, half), position + SIMD3(half, -half, half),
                position + SIMD3(half, half, half), position + SIMD3(-half, half, half)
            ]
            let edges: [(Int, Int)] = [
                (0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)
            ]
            for (a, b) in edges { appendVertex(corners[a], color); appendVertex(corners[b], color) }
        }
        guard !floats.isEmpty else {
            crossEngineLineBuffer = nil
            crossEngineLineVertexCount = 0
            return
        }
        crossEngineLineVertexCount = floats.count / 6
        crossEngineLineBuffer = device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    // MARK: - The Forge Palette: new-item placement (Part 4C)

    /// "I must be able to select an entity from this directory, click into
    /// the 3D map, and spawn a brand-new instance of that object" — set
    /// non-nil to arm placement mode (the next viewport click places this
    /// object instead of orbiting/picking; see `InteractiveMTKView.
    /// mouseDown`), `nil` to cancel it without placing anything.
    var pendingPlacementObjectID: UInt16?

    /// Resolves `objectID` to real geometry through the same
    /// `AssetResolver.resolveInstanceObject` chain every existing
    /// `Instance` already goes through (falling back to the amber marker
    /// cube when it doesn't resolve — same "colored bounding-box proxy"
    /// rule as everywhere else), places it at `worldPosition`, and assigns
    /// it a synthetic `Instance` ID that doesn't collide with any real one
    /// already in this level (`nextSyntheticInstanceID`, seeded one past
    /// the highest real ID at load and incremented on every spawn — even
    /// across undo/redo, so a redone spawn never accidentally reuses an ID
    /// a *different* still-live placement claimed in between). Selects the
    /// new object immediately, same as `addObject`, so its gizmo is ready.
    /// Whether `objectID` would resolve to real geometry through the same
    /// chain `spawnInstance` uses (this level's own `assetIndex`, falling
    /// back to the shared `Default.rm2` `defaultAssetIndex`) — checked
    /// without touching the GPU. The Forge Palette lists every object ID in
    /// the whole game (`DefaultObjectID.names` isn't scoped per-level,
    /// since no per-level roster is decoded anywhere in this build), so
    /// picking an ID this level's data genuinely has no geometry for is a
    /// legitimate, expected outcome, not a resolver bug — this lets the
    /// palette say so upfront instead of the user only finding out after
    /// already placing an amber placeholder cube.
    func canResolveObjectID(_ objectID: UInt16) -> Bool {
        guard let resolved = AssetResolver.resolveInstanceObject(objectID: objectID, instanceSelector: 0, index: assetIndex, defaultIndex: defaultAssetIndex) else { return false }
        return !resolved.mesh.submeshes.isEmpty
    }

    @discardableResult
    func spawnInstance(objectID: UInt16, at worldPosition: SIMD3<Float>) -> Int? {
        let markerMesh = Self.makeMarkerCubeAsset()
        var submeshes = ModelViewerRenderer.buildGPUSubmeshes(mesh: markerMesh.mesh, submeshMaterials: [markerMesh.material], device: device, fallbackTexture: context.fallbackTexture).submeshes
        var radius = Self.boundingRadius(of: markerMesh.mesh)
        var displayName = "New Object #\(objectID)"
        if let resolved = AssetResolver.resolveInstanceObject(objectID: objectID, instanceSelector: 0, index: assetIndex, defaultIndex: defaultAssetIndex) {
            let built = ModelViewerRenderer.buildGPUSubmeshes(mesh: resolved.mesh, submeshMaterials: resolved.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture)
            if !built.submeshes.isEmpty {
                submeshes = built.submeshes
                radius = Self.boundingRadius(of: resolved.mesh)
                displayName = resolved.displayName
            }
        }
        guard !submeshes.isEmpty else { return nil }

        let syntheticID = nextSyntheticInstanceID
        nextSyntheticInstanceID += 1
        objects.append(GPULevelObject(
            worldPosition: worldPosition,
            displayName: displayName,
            submeshes: submeshes,
            layer: .actors,
            boundingRadius: radius,
            newInstanceObjectID: objectID,
            syntheticInstanceID: syntheticID
        ))
        let newIndex = objects.count - 1
        select(index: newIndex)
        return newIndex
    }

    /// `LevelViewerWindow`'s placement-undo registration needs to snapshot
    /// what a just-placed object *was* (its `objectID` and where it ended
    /// up) without this renderer exposing its private `objects` array
    /// wholesale — this is that one narrow read.
    func newInstanceInfo(at index: Int) -> (objectID: UInt16, worldPosition: SIMD3<Float>)? {
        guard objects.indices.contains(index), let objectID = objects[index].newInstanceObjectID else { return nil }
        return (objectID, objects[index].worldPosition)
    }

    /// Whether `duplicateSelectedObject` could actually do anything for
    /// the object at `index` right now — lets the UI disable/explain the
    /// Duplicate button up front instead of the action silently no-oping.
    func canDuplicate(at index: Int) -> Bool {
        guard objects.indices.contains(index) else { return false }
        let object = objects[index]
        switch object.layer {
        case .actors:
            return object.newInstanceObjectID != nil || (object.sourceNode.flatMap { instanceObjectIDByNodeID[$0.id] } != nil)
        case .aiWaypoints:
            return true
        default:
            return false
        }
    }

    /// "Unrestricted Chunk Free-Edit Mode": duplicate the selected object
    /// a short offset from its current position, through the exact same
    /// real spawn+write-back pipeline `spawnInstance`/`spawnAIWaypoint`
    /// already give the Forge Palette — the duplicate becomes a real new
    /// record on save, not a purely visual copy nobody can persist.
    /// Actors and AI waypoints are the only layers with a real spawn
    /// primitive to duplicate through; scenery/trigger/camera placements
    /// still have no write path of any kind (long-standing, unchanged by
    /// this), so duplicating them isn't offered — `nil`, not a fabricated
    /// copy that would silently vanish on save.
    @discardableResult
    func duplicateSelectedObject() -> Int? {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return nil }
        let object = objects[selectedObjectIndex]
        let offsetPosition = object.worldPosition + SIMD3<Float>(1, 0, 1)
        switch object.layer {
        case .actors:
            let objectID = object.newInstanceObjectID ?? object.sourceNode.flatMap { instanceObjectIDByNodeID[$0.id] }
            guard let objectID else { return nil }
            return spawnInstance(objectID: objectID, at: offsetPosition)
        case .aiWaypoints:
            let rawNodeType = object.newAIWaypointRawNodeType ?? object.originalAIWaypointRawNodeType ?? 0
            return spawnAIWaypoint(at: offsetPosition, rawNodeType: rawNodeType)
        default:
            return nil
        }
    }

    /// "AI Pathfinding & Navmesh Editor" (roadmap 5.1): appends a brand-new
    /// waypoint marker at `worldPosition` (defaulting to the level's own
    /// visual center, same "as good a default drop point as any" reasoning
    /// as `addObject`'s own doc comment) with a synthetic `AIPosition` ID
    /// (namespaced separately from `spawnInstance`'s — see
    /// `nextSyntheticAIPositionID`'s doc comment), selects it immediately.
    /// `rawNodeType` defaults to `0` (`AIPositionMarker.NodeType.ground`)
    /// — the most common real value, not a guess dressed up as a default;
    /// still fully editable before saving.
    @discardableResult
    func spawnAIWaypoint(at worldPosition: SIMD3<Float>? = nil, rawNodeType: UInt16 = 0) -> Int? {
        let worldPosition = worldPosition ?? boundsCenter
        let syntheticID = nextSyntheticAIPositionID
        nextSyntheticAIPositionID += 1
        objects.append(GPULevelObject(
            worldPosition: worldPosition,
            displayName: "New AI Waypoint #\(syntheticID)",
            submeshes: [],
            layer: .aiWaypoints,
            newAIWaypointRawNodeType: rawNodeType,
            syntheticAIPositionID: syntheticID
        ))
        let newIndex = objects.count - 1
        select(index: newIndex)
        return newIndex
    }

    /// Same role as `newInstanceInfo`, for `spawnAIWaypoint`'s undo path.
    func newAIWaypointInfo(at index: Int) -> (rawNodeType: UInt16, worldPosition: SIMD3<Float>)? {
        guard objects.indices.contains(index), let rawNodeType = objects[index].newAIWaypointRawNodeType else { return nil }
        return (rawNodeType, objects[index].worldPosition)
    }

    /// The undo/redo-reachable counterpart to `spawnInstance` — removes
    /// whatever object currently sits at `index`. Callers (`LevelViewerWindow`'s
    /// undo registration) are responsible for only ever calling this with an
    /// index that's still valid for the current `objects` array; same
    /// bounds-check-and-no-op-if-stale posture as `select(index:)`.
    func removeObject(at index: Int) {
        guard objects.indices.contains(index) else { return }
        objects.remove(at: index)
        if selectedObjectIndex == index {
            select(index: nil)
        } else if let selectedObjectIndex, selectedObjectIndex > index {
            select(index: selectedObjectIndex - 1)
        }
    }

    /// "Backend Requirement: calculate the XYZ position" — every object
    /// placed via the palette that hasn't been saved yet, ready to hand to
    /// a real record-injection writer. Position/rotation/scale come
    /// straight off the live `GPULevelObject`, same as `pendingLevelOverrides`.
    var pendingNewInstances: [(objectID: UInt16, syntheticID: UInt32, position: SIMD3<Float>, rotationDegrees: SIMD3<Float>)] {
        objects.compactMap { object in
            guard let objectID = object.newInstanceObjectID, let syntheticID = object.syntheticInstanceID else { return nil }
            return (objectID, syntheticID, object.worldPosition, Self.eulerDegrees(from: object.rotation))
        }
    }

    /// "AI Pathfinding & Navmesh Editor" (roadmap 5.1): the current
    /// position of every *existing, real* AI waypoint marker, re-encoded
    /// and paired with the `ChunkNode` it patches into — the waypoint
    /// counterpart to `pendingLevelOverrides`. `.aiWaypoints`-layer only,
    /// same reasoning as `pendingLevelOverrides`'s own `.actors`-only
    /// guard: applying an `AIPosition` encode to any other record type
    /// would corrupt it.
    var pendingAIWaypointOverrides: [(node: ChunkNode, encoded: Data)] {
        objects.compactMap { object in
            guard object.layer == .aiWaypoints, let node = object.sourceNode,
                  let rawNodeType = object.originalAIWaypointRawNodeType
            else { return nil }
            let position = SIMD4(object.worldPosition.x, object.worldPosition.y, object.worldPosition.z, object.originalPositionW)
            let encoded = WorldPlacementWriter.writeAIPosition(position: position, rawNodeType: rawNodeType)
            return (node, encoded)
        }
    }

    /// "Spline & Camera Path Persistence" (roadmap 6.3): the current
    /// position of every real, on-disk Camera Path/Spline control point,
    /// paired with the owning Camera `ChunkNode` and the exact absolute
    /// file offset (`node.fileOffset + cameraControlPointFileOffset`) this
    /// one point's 16 bytes patch into — deliberately not keyed by
    /// `.cameras`-layer alone (that also matches each camera's own box
    /// marker, which has no `cameraControlPointFileOffset` and would
    /// otherwise get misencoded as a control point).
    var pendingCameraControlPointOverrides: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)] {
        objects.compactMap { object in
            guard object.layer == .cameras, let node = object.sourceNode,
                  let relativeOffset = object.cameraControlPointFileOffset
            else { return nil }
            let vector = SIMD4(object.worldPosition.x, object.worldPosition.y, object.worldPosition.z, object.originalPositionW)
            let encoded = WorldPlacementWriter.writeCameraControlPoint(vector)
            return (node, node.fileOffset + relativeOffset, encoded)
        }
    }

    /// Every waypoint placed this session via `spawnAIWaypoint`, ready to
    /// hand to `WorkspaceViewModel.patchedFileBytes(applyingPrefixPatches:
    /// insertingNewAIPositions:levelNode:)` — the waypoint counterpart to
    /// `pendingNewInstances`.
    var pendingNewAIPositions: [(id: UInt32, encoded: Data)] {
        objects.compactMap { object in
            guard let rawNodeType = object.newAIWaypointRawNodeType, let syntheticID = object.syntheticAIPositionID else { return nil }
            let encoded = WorldPlacementWriter.writeAIPosition(position: SIMD4(object.worldPosition, 1), rawNodeType: rawNodeType)
            return (syntheticID, encoded)
        }
    }

    /// Unprojects a screen point through the inverse view-projection at two
    /// depths (Metal NDC `z = 0`/near and `z = 1`/far — see `Frustum`'s own
    /// doc comment for why this build's near/far convention isn't the
    /// generic OpenGL one) to get a world-space ray, then intersects it
    /// with a horizontal plane at `planeY`. This is a deliberate
    /// simplification — a real "click on the ground" needs a ray/mesh hit
    /// test against the actual scenery geometry, which this build doesn't
    /// have collision data wired up for in the Level Viewer — not a claim
    /// that clicking always lands exactly on visible terrain. `nil` when
    /// the click is aimed away from the plane entirely (e.g. straight up).
    func worldPositionOnGroundPlane(at screenPoint: CGPoint, viewSize: CGSize, planeY: Float) -> SIMD3<Float>? {
        let viewProjection = currentViewProjection(viewSize: viewSize)
        let inverse = viewProjection.inverse
        let ndcX = Float(screenPoint.x / max(viewSize.width, 1)) * 2 - 1
        let ndcY = Float(screenPoint.y / max(viewSize.height, 1)) * 2 - 1

        func unproject(ndcZ: Float) -> SIMD3<Float>? {
            let clip = inverse * SIMD4<Float>(ndcX, ndcY, ndcZ, 1)
            guard abs(clip.w) > 0.0001 else { return nil }
            return SIMD3(clip.x, clip.y, clip.z) / clip.w
        }
        guard let nearPoint = unproject(ndcZ: 0), let farPoint = unproject(ndcZ: 1) else { return nil }
        let direction = farPoint - nearPoint
        guard abs(direction.y) > 0.0001 else { return nil }

        let t = (planeY - nearPoint.y) / direction.y
        guard t > 0 else { return nil }
        return nearPoint + direction * t
    }

    /// "The Forge Palette": a `mouseDown` in placement mode (armed via
    /// `pendingPlacementObjectID`) resolves to a world position on this
    /// ground-plane heuristic — the level's own vertical center, the same
    /// "no per-object size data to do better" reasoning `expandBounds`
    /// already uses for scenery bounds — then spawns the object there and
    /// disarms placement mode (one shot per palette click, matching how
    /// dragging one item from the Models Hub places exactly one object).
    @discardableResult
    func placeObject(at screenPoint: CGPoint, viewSize: CGSize) -> Int? {
        guard let objectID = pendingPlacementObjectID,
              let worldPosition = worldPositionOnGroundPlane(at: screenPoint, viewSize: viewSize, planeY: boundsCenter.y)
        else { return nil }
        pendingPlacementObjectID = nil
        return spawnInstance(objectID: objectID, at: worldPosition)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// The exact camera math `draw(in:)` uses, factored out so the gizmo
    /// hit test and drag math (`gizmoAxis(at:viewSize:)`,
    /// `dragSelectedObject`) project between world and screen space with
    /// the identical matrix the current frame was actually drawn with —
    /// any drift between the two would make the gizmo arrows visually not
    /// match where clicks/drags actually register.
    /// "F to Focus/Frame": the orbit look-at point is the selected object's
    /// position when there is one, falling back to the whole level's
    /// bounds center otherwise — selecting something re-centers the camera
    /// on it automatically, without needing a separate "frame selection"
    /// action. `boundsRadius`/`boundsCenter` themselves stay level-wide
    /// (they also drive the far clip plane and the gizmo's arm length), so
    /// this only changes *where the camera looks*, not the scene's overall
    /// scale.
    private var orbitTarget: SIMD3<Float> { selectedPosition ?? boundsCenter }

    private func currentViewProjection(viewSize: CGSize) -> simd_float4x4 {
        let aspect = Float(viewSize.width / max(viewSize.height, 1))
        let projection = ModelViewerRenderer.perspectiveMatrix(fovYRadians: .pi / 4, aspect: aspect, near: 0.05, far: boundsRadius * 20 + 50)
        let view4x4: simd_float4x4
        if isFreeCameraMode {
            view4x4 = ModelViewerRenderer.lookAtMatrix(eye: freeCameraPosition, center: freeCameraPosition + freeCameraForward(), up: SIMD3<Float>(0, 1, 0))
        } else {
            view4x4 = ModelViewerRenderer.lookAtMatrix(eye: orbitEyeWorldPosition, center: orbitTarget, up: SIMD3<Float>(0, 1, 0))
        }
        return projection * view4x4
    }

    private var orbitEyeWorldPosition: SIMD3<Float> {
        let distance = boundsRadius * distanceMultiplier
        let target = orbitTarget
        return SIMD3<Float>(
            target.x + distance * cos(pitch) * sin(yaw),
            target.y + distance * sin(pitch),
            target.z + distance * cos(pitch) * cos(yaw)
        )
    }

    /// "Active Chunk & Asset Preview Engine" (roadmap 7.1) — the current
    /// camera's real world-space eye position: the orbit formula, or the
    /// free camera's own tracked position when that mode is active.
    /// Exposed so "Scene Preview Mode" can test it against real decoded
    /// Trigger volumes as a free-look "where is the camera standing"
    /// proxy — an honest simplification (this is a camera, not a
    /// first-person player controller/physics body) stated as such in the
    /// Level Viewer's own UI, not dressed up as gameplay.
    var cameraEyeWorldPosition: SIMD3<Float> {
        isFreeCameraMode ? freeCameraPosition : orbitEyeWorldPosition
    }

    /// "F to Focus/Frame" — resets angle/distance to a sensible default;
    /// combined with `orbitTarget` above, pressing F while something's
    /// selected reads as "frame the selected object."
    func resetView() {
        yaw = .pi * 0.25
        pitch = .pi * 0.3
        distanceMultiplier = 1.4
    }

    // MARK: - Free Camera ("Free Camera System in Chunk Editor")

    /// A real, independent 6-DOF flying camera — distinct from the orbit
    /// camera above (`yaw`/`pitch`/`distanceMultiplier` orbit a fixed
    /// target; this one has its own world position and looks wherever
    /// it's pointed, with no target to orbit around). Off by default.
    /// Entering the mode starts from wherever the orbit camera currently
    /// is/looks, derived from the real orbit eye and look-at direction —
    /// not reset to the origin — so toggling it on never jump-cuts the
    /// view.
    var isFreeCameraMode = false {
        didSet {
            guard isFreeCameraMode, !oldValue else { return }
            let eye = orbitEyeWorldPosition
            freeCameraPosition = eye
            let lookDirection = simd_normalize(orbitTarget - eye)
            freeCameraPitch = asin(max(-1, min(1, lookDirection.y)))
            freeCameraYaw = atan2(lookDirection.x, lookDirection.z)
            freeCameraVelocity = .zero
        }
    }
    private var freeCameraPosition: SIMD3<Float> = .zero
    private var freeCameraYaw: Float = 0
    private var freeCameraPitch: Float = 0
    /// Units/second — real "adjustable movement speed" (Scroll Wheel),
    /// clamped to a sane range by whatever adjusts it.
    var freeCameraSpeed: Float = 20
    /// Smoothed current velocity, world-space — accelerated toward the
    /// requested input direction and decayed back toward zero each frame
    /// in `updateFreeCameraMovement`, the "smooth velocity damping" the
    /// mandate asks for instead of an instant on/off snap.
    private var freeCameraVelocity: SIMD3<Float> = .zero
    /// Local-space (x = right/left from A/D, y = up/down from E/Q,
    /// z = forward/back from W/S) input vector — set from currently-held
    /// keys on every `keyDown`/`keyUp`, consumed once per frame in
    /// `draw(in:)` so movement is continuous and frame-rate independent,
    /// not one discrete step per keystroke.
    var freeCameraInputDirection: SIMD3<Float> = .zero
    private var lastFrameTimestamp: CFTimeInterval?

    private func freeCameraForward() -> SIMD3<Float> {
        SIMD3(cos(freeCameraPitch) * sin(freeCameraYaw), sin(freeCameraPitch), cos(freeCameraPitch) * cos(freeCameraYaw))
    }
    private func freeCameraRight() -> SIMD3<Float> {
        SIMD3(cos(freeCameraYaw), 0, -sin(freeCameraYaw))
    }

    /// Right-click-drag look — real, continuous yaw/pitch, clamped so the
    /// camera can't flip past straight up/down.
    func rotateFreeCameraLook(yawDelta: Float, pitchDelta: Float) {
        freeCameraYaw += yawDelta
        freeCameraPitch = max(-1.5, min(1.5, freeCameraPitch + pitchDelta))
    }

    /// Integrates one frame of free-camera movement. No collision — the
    /// mandate explicitly asks for zero-collision flight, matching this
    /// build's real physics gap (there's no collision-response system to
    /// stop against anyway, so this isn't cutting a corner, it's the only
    /// honest behavior available).
    /// Internal (not `private`) so `@testable import` can drive this with
    /// an explicit, deterministic `deltaTime` instead of depending on
    /// real wall-clock timing through `draw(in:)`.
    func updateFreeCameraMovement(deltaTime: Float) {
        guard isFreeCameraMode else { return }
        let clampedDT = min(max(deltaTime, 0), 1.0 / 15.0) // guards a huge dt after a stall/pause
        let worldInputDirection = freeCameraRight() * freeCameraInputDirection.x
            + SIMD3<Float>(0, 1, 0) * freeCameraInputDirection.y
            + freeCameraForward() * freeCameraInputDirection.z
        let targetVelocity = (simd_length(worldInputDirection) > 0.0001 ? simd_normalize(worldInputDirection) : .zero) * freeCameraSpeed
        let accelerationRate: Float = 8.0
        freeCameraVelocity += (targetVelocity - freeCameraVelocity) * min(1, accelerationRate * clampedDT)
        freeCameraPosition += freeCameraVelocity * clampedDT
    }

    func draw(in view: MTKView) {
        // Real elapsed time since the previous frame — free-camera speed
        // is expressed in units/second, so this has to be measured, not
        // assumed from `preferredFramesPerSecond` (which is a request to
        // the display link, not a guarantee).
        let now = CACurrentMediaTime()
        let deltaTime = lastFrameTimestamp.map { Float(now - $0) } ?? 0
        lastFrameTimestamp = now
        updateFreeCameraMovement(deltaTime: deltaTime)

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let viewProjection = currentViewProjection(viewSize: view.bounds.size)
        let lightDirection = normalize(SIMD3<Float>(-0.4, -1.0, -0.3))

        encoder.setRenderPipelineState(context.pipelineState)
        encoder.setDepthStencilState(context.depthState)
        encoder.setFragmentSamplerState(context.samplerState, index: 0)

        // "Seamless Full-Map Rendering" (Part 1): one frustum per frame,
        // reused for every object's cull test below — a massive level can
        // have hundreds of scenery/actor placements, and skipping the
        // uniform upload + draw call entirely for whatever's behind the
        // camera or well outside the view cone is the direct lever for
        // flying a free-cam around it without dropping frames.
        let frustum = ModelViewerRenderer.Frustum(viewProjection: viewProjection)

        for object in objects where layerVisibility.contains(object.layer) {
            let maxScale = max(object.scale.x, max(object.scale.y, object.scale.z))
            guard frustum.intersects(center: object.worldPosition, radius: object.boundingRadius * maxScale) else { continue }
            // T * R * S: scale and rotate the local mesh first, then place
            // the result at the object's world position — the standard
            // TRS composition order (reversed relative to how it reads
            // left-to-right, since these matrices apply right-to-left).
            let model = simd_float4x4(translation: object.worldPosition)
                * simd_float4x4(object.rotation)
                * simd_float4x4(diagonal: SIMD4(object.scale.x, object.scale.y, object.scale.z, 1))
            var uniforms = Uniforms(modelViewProjection: viewProjection * model, modelMatrix: model, lightDirection: lightDirection)
            for submesh in object.submeshes {
                encoder.setVertexBuffer(submesh.vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setFragmentTexture(submesh.texture, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: submesh.indexCount, indexType: .uint32, indexBuffer: submesh.indexBuffer, indexBufferOffset: 0)
            }
        }

        if let coloredPipeline = context.collisionLineColoredPipelineState {
            var uniforms = Uniforms(modelViewProjection: viewProjection, modelMatrix: matrix_identity_float4x4, lightDirection: lightDirection)
            encoder.setRenderPipelineState(coloredPipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            // "Level Editor Overhaul": trigger/camera wireframes, same line
            // pipeline and vertex layout as the gizmo below — both are
            // interleaved position+color buffers, so they share one setup.
            if let overlayLineBuffer {
                encoder.setVertexBuffer(overlayLineBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: overlayLineVertexCount)
            }
            if let gizmoBuffer {
                encoder.setVertexBuffer(gizmoBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gizmoVertexCount)
            }
            // "Cross-Engine Chunk Stitcher" (roadmap 5.3).
            if layerVisibility.contains(.crossEngine), let crossEngineLineBuffer, crossEngineLineVertexCount > 0 {
                encoder.setVertexBuffer(crossEngineLineBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: crossEngineLineVertexCount)
            }
        }

        // "Chunk-Based Architecture" (Part 2): the translucent boundary-
        // wall fill, drawn last (after opaque geometry and wireframes) with
        // depth write disabled so it doesn't corrupt the depth buffer for
        // anything drawn after it, and with culling off since the real
        // corner winding of a decoded `loadWall` quad isn't independently
        // confirmed.
        if let translucentPipeline = context.translucentQuadPipelineState, let chunkWallTriangleBuffer, chunkWallTriangleVertexCount > 0 {
            var uniforms = Uniforms(modelViewProjection: viewProjection, modelMatrix: matrix_identity_float4x4, lightDirection: lightDirection)
            encoder.setRenderPipelineState(translucentPipeline)
            encoder.setDepthStencilState(context.translucentDepthState)
            encoder.setCullMode(.none)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setVertexBuffer(chunkWallTriangleBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: chunkWallTriangleVertexCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Gizmo geometry, hit-testing, and dragging (blueprint 6.1)

    private var gizmoVertexCount = 0

    /// Builds the gizmo's line geometry — one shaft plus a small two-line
    /// arrowhead per axis — as an interleaved position+color buffer
    /// (`vertex_line_colored`'s `LineVertexColorIn` layout, the same one
    /// `ModelViewerRenderer`'s by-surface-ID collision wireframe uses).
    /// Rebuilt only on selection change or an actual position edit, not
    /// per-frame — same caching rationale as `ModelViewerRenderer`'s own
    /// line buffers.
    private func rebuildGizmoBuffer() {
        // Triggers/cameras are select-and-inspect only — no gizmo, since
        // this build has no verified byte-exact encoder for either record
        // type (see `pendingLevelOverrides`'s guard). Showing a draggable
        // gizmo on one anyway would let it *look* editable while any drag
        // silently vanishes on save.
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex),
              objects[selectedObjectIndex].layer == .scenery || objects[selectedObjectIndex].layer == .actors
        else {
            gizmoBuffer = nil
            gizmoVertexCount = 0
            return
        }
        let origin = objects[selectedObjectIndex].worldPosition
        let armLength = gizmoArmLength

        var floats: [Float] = []
        func appendVertex(_ position: SIMD3<Float>, _ color: SIMD3<Float>) {
            floats.append(contentsOf: [position.x, position.y, position.z, color.x, color.y, color.z])
        }

        switch gizmoMode {
        case .translate, .scale:
            // Scale mode reuses the exact same arrow geometry as
            // translate — a real cube/box tip to distinguish them
            // visually is more line-pipeline complexity than the
            // distinction is worth; the sidebar's mode picker (and the
            // fields it drives) already make it unambiguous which one is
            // active.
            let headSize = armLength * 0.18
            for axis in GizmoAxis.allCases {
                let tip = origin + axis.unitVector * armLength
                appendVertex(origin, axis.color)
                appendVertex(tip, axis.color)

                // A tiny 2-line "V" arrowhead, angled back from the tip
                // along one other axis — enough to read as a direction
                // marker without needing a real cone mesh in a line-only
                // pipeline.
                let others = GizmoAxis.allCases.filter { $0.unitVector != axis.unitVector }
                for other in others.prefix(1) {
                    let back = tip - axis.unitVector * headSize
                    appendVertex(tip, axis.color)
                    appendVertex(back + other.unitVector * headSize, axis.color)
                    appendVertex(tip, axis.color)
                    appendVertex(back - other.unitVector * headSize, axis.color)
                }
            }

        case .rotate:
            // Three rings, one per axis, each drawn flat in that axis's
            // own perpendicular plane (see `GizmoAxis.planeBasis`) —
            // approximated as `ringSegments` short line segments rather
            // than a real curved primitive, same "good enough for a line
            // pipeline" approach as the arrowheads above.
            let ringSegments = Self.gizmoRingSegments
            for axis in GizmoAxis.allCases {
                let (u, v) = axis.planeBasis
                for i in 0..<ringSegments {
                    let theta0 = Float(i) / Float(ringSegments) * 2 * .pi
                    let theta1 = Float(i + 1) / Float(ringSegments) * 2 * .pi
                    let p0 = origin + armLength * (cos(theta0) * u + sin(theta0) * v)
                    let p1 = origin + armLength * (cos(theta1) * u + sin(theta1) * v)
                    appendVertex(p0, axis.color)
                    appendVertex(p1, axis.color)
                }
            }
        }

        gizmoVertexCount = floats.count / 6
        gizmoBuffer = device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    private static let gizmoRingSegments = 48

    private static func project(_ worldPosition: SIMD3<Float>, viewProjection: simd_float4x4, viewSize: CGSize) -> CGPoint? {
        let clip = viewProjection * SIMD4<Float>(worldPosition, 1)
        guard clip.w > 0.0001 else { return nil }
        let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
        // NDC is x-right/y-up in Metal, same handedness as an *unflipped*
        // AppKit view's own point space (origin bottom-left, y up) — no
        // flip needed to go from one to the other, unlike a flipped view or
        // a top-left-origin UI coordinate system.
        return CGPoint(x: (Double(ndc.x) * 0.5 + 0.5) * viewSize.width, y: (Double(ndc.y) * 0.5 + 0.5) * viewSize.height)
    }

    private static func distance(from point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        guard lengthSquared > 0.0001 else {
            return hypot(point.x - a.x, point.y - a.y)
        }
        let t = max(0, min(1, ((point.x - a.x) * abx + (point.y - a.y) * aby) / lengthSquared))
        let projX = a.x + t * abx, projY = a.y + t * aby
        return hypot(point.x - projX, point.y - projY)
    }

    /// `viewSize` is the `NSView.bounds.size` of whatever's calling this
    /// (points, not backing pixels) — deliberately the same unit as
    /// `NSEvent`'s own coordinates, so no Retina-scale conversion is needed
    /// anywhere in this hit test.
    func gizmoAxis(at point: CGPoint, viewSize: CGSize) -> GizmoAxis? {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return nil }
        let origin = objects[selectedObjectIndex].worldPosition
        let viewProjection = currentViewProjection(viewSize: viewSize)

        switch gizmoMode {
        case .translate, .scale:
            guard let originScreen = Self.project(origin, viewProjection: viewProjection, viewSize: viewSize) else { return nil }
            var best: (axis: GizmoAxis, distance: CGFloat)?
            for axis in GizmoAxis.allCases {
                let tip = origin + axis.unitVector * gizmoArmLength
                guard let tipScreen = Self.project(tip, viewProjection: viewProjection, viewSize: viewSize) else { continue }
                let d = Self.distance(from: point, toSegmentFrom: originScreen, to: tipScreen)
                if d < 14, (best == nil || d < best!.distance) {
                    best = (axis, d)
                }
            }
            return best?.axis

        case .rotate:
            var best: (axis: GizmoAxis, distance: CGFloat)?
            for axis in GizmoAxis.allCases {
                let (u, v) = axis.planeBasis
                var previousScreen: CGPoint?
                for i in 0...Self.gizmoRingSegments {
                    let theta = Float(i) / Float(Self.gizmoRingSegments) * 2 * .pi
                    let p = origin + gizmoArmLength * (cos(theta) * u + sin(theta) * v)
                    guard let screen = Self.project(p, viewProjection: viewProjection, viewSize: viewSize) else {
                        previousScreen = nil
                        continue
                    }
                    if let previousScreen {
                        let d = Self.distance(from: point, toSegmentFrom: previousScreen, to: screen)
                        if d < 10, (best == nil || d < best!.distance) {
                            best = (axis, d)
                        }
                    }
                    previousScreen = screen
                }
            }
            return best?.axis
        }
    }

    /// "Click any rendered element to select it" (Level Editor overhaul):
    /// see `GizmoInteractiveRenderer.pickObject`'s doc comment for the
    /// technique. Only considers objects on a currently-visible layer, so a
    /// hidden trigger/camera/actor can't be selected by clicking through
    /// where it used to be.
    func pickObject(at point: CGPoint, viewSize: CGSize) -> Int? {
        let viewProjection = currentViewProjection(viewSize: viewSize)
        var best: (index: Int, distance: CGFloat)?
        for (index, object) in objects.enumerated() where layerVisibility.contains(object.layer) {
            guard let screen = Self.project(object.worldPosition, viewProjection: viewProjection, viewSize: viewSize) else { continue }
            let d = hypot(point.x - screen.x, point.y - screen.y)
            if d < 22, (best == nil || d < best!.distance) {
                best = (index, d)
            }
        }
        return best?.index
    }

    /// Standard screen-space axis-constrained drag: project the selected
    /// object's origin and the grabbed axis's tip into screen space, take
    /// the mouse's raw delta, and scalar-project it onto that screen-space
    /// axis direction to get "how far along the arrow did the mouse move"
    /// — then convert that back into world units using the known
    /// world-length/screen-length ratio of the same arrow. Shared by
    /// translate and scale drags; rotate uses a different (simpler)
    /// technique — see `dragRotate`.
    private static func axisProjectedWorldDelta(viewportDelta: CGVector, originScreen: CGPoint, tipScreen: CGPoint, armLength: Float) -> Float? {
        let axisScreenX = tipScreen.x - originScreen.x
        let axisScreenY = tipScreen.y - originScreen.y
        let axisScreenLength = hypot(axisScreenX, axisScreenY)
        guard axisScreenLength > 0.5 else { return nil }

        // `event.deltaY` is positive for *downward* mouse motion (matching
        // this file's existing orbit-drag code, `renderer.pitch += deltaY *
        // 0.01`), while `project(...)`'s screen space is y-up — so `dy` is
        // negated before use. This (and the overall drag feel) is derived
        // from the documented Metal NDC/AppKit coordinate conventions, not
        // verified interactively — there's no way to drive a real
        // mouse-drag gesture from this build environment, so test the
        // actual feel by hand.
        let mouseX = viewportDelta.dx
        let mouseY = -viewportDelta.dy
        let projectedLength = (mouseX * axisScreenX + mouseY * axisScreenY) / axisScreenLength
        let worldPerScreenPoint = Double(armLength) / Double(axisScreenLength)
        return Float(projectedLength * worldPerScreenPoint)
    }

    func dragSelectedObject(axis: GizmoAxis, viewportDelta: CGVector, viewSize: CGSize) {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return }
        switch gizmoMode {
        case .translate: dragTranslate(axis: axis, viewportDelta: viewportDelta, viewSize: viewSize, index: selectedObjectIndex)
        case .scale: dragScale(axis: axis, viewportDelta: viewportDelta, viewSize: viewSize, index: selectedObjectIndex)
        case .rotate: dragRotate(axis: axis, viewportDelta: viewportDelta, index: selectedObjectIndex)
        }
    }

    private func dragTranslate(axis: GizmoAxis, viewportDelta: CGVector, viewSize: CGSize, index: Int) {
        let origin = objects[index].worldPosition
        let viewProjection = currentViewProjection(viewSize: viewSize)
        guard let originScreen = Self.project(origin, viewProjection: viewProjection, viewSize: viewSize),
              let tipScreen = Self.project(origin + axis.unitVector * gizmoArmLength, viewProjection: viewProjection, viewSize: viewSize),
              let worldDelta = Self.axisProjectedWorldDelta(viewportDelta: viewportDelta, originScreen: originScreen, tipScreen: tipScreen, armLength: gizmoArmLength)
        else { return }

        var newPosition = origin + axis.unitVector * worldDelta
        if snapToGrid, gridSize > 0.0001 {
            func snap(_ value: Float) -> Float { (value / gridSize).rounded() * gridSize }
            switch axis {
            case .x: newPosition.x = snap(newPosition.x)
            case .y: newPosition.y = snap(newPosition.y)
            case .z: newPosition.z = snap(newPosition.z)
            }
        }
        objects[index].worldPosition = newPosition
        rebuildGizmoBuffer()
    }

    /// Same screen-space axis-projection technique as `dragTranslate`, but
    /// the resulting world-space delta is interpreted as a *fraction of
    /// the gizmo's own arm length* added to the current scale on that axis
    /// — dragging the full visible length of the arrow roughly doubles the
    /// scale, which reads as a reasonably proportional "how far I dragged
    /// maps to how much bigger it got" feel without needing a separate
    /// calibration constant.
    private func dragScale(axis: GizmoAxis, viewportDelta: CGVector, viewSize: CGSize, index: Int) {
        let origin = objects[index].worldPosition
        let viewProjection = currentViewProjection(viewSize: viewSize)
        guard let originScreen = Self.project(origin, viewProjection: viewProjection, viewSize: viewSize),
              let tipScreen = Self.project(origin + axis.unitVector * gizmoArmLength, viewProjection: viewProjection, viewSize: viewSize),
              let worldDelta = Self.axisProjectedWorldDelta(viewportDelta: viewportDelta, originScreen: originScreen, tipScreen: tipScreen, armLength: gizmoArmLength)
        else { return }

        let scaleDelta = worldDelta / gizmoArmLength
        var newScale = objects[index].scale
        switch axis {
        case .x: newScale.x += scaleDelta
        case .y: newScale.y += scaleDelta
        case .z: newScale.z += scaleDelta
        }
        if snapToGrid, gridSize > 0.0001 {
            func snap(_ value: Float) -> Float { (value / gridSize).rounded() * gridSize }
            switch axis {
            case .x: newScale.x = snap(newScale.x)
            case .y: newScale.y = snap(newScale.y)
            case .z: newScale.z = snap(newScale.z)
            }
        }
        // Same reasoning as `setSelectedScale`'s clamp: a zero/negative
        // scale is visually indistinguishable from "nothing renders."
        objects[index].scale = SIMD3(max(newScale.x, 0.01), max(newScale.y, 0.01), max(newScale.z, 0.01))
        rebuildGizmoBuffer()
    }

    /// Deliberately simpler than translate/scale: rather than computing
    /// the exact angle swept around a screen-projected ring (a circle in
    /// world space becomes an ellipse in screen space under perspective,
    /// and the angle math to invert that correctly is real extra
    /// complexity), horizontal mouse motion directly drives rotation
    /// speed around the grabbed axis — the same simplified "drag to spin"
    /// interaction most lightweight in-house gizmos actually use.
    private func dragRotate(axis: GizmoAxis, viewportDelta: CGVector, index: Int) {
        let degreesPerPoint: Float = 0.5
        let deltaRadians = Float(viewportDelta.dx) * degreesPerPoint * .pi / 180
        let deltaRotation = simd_quatf(angle: deltaRadians, axis: axis.unitVector)
        var newRotation = simd_normalize(deltaRotation * objects[index].rotation)

        if snapToGrid, rotationSnapDegrees > 0.0001 {
            let euler = Self.eulerDegrees(from: newRotation)
            func snap(_ value: Float) -> Float { (value / rotationSnapDegrees).rounded() * rotationSnapDegrees }
            newRotation = Self.quaternion(fromEulerDegrees: SIMD3(snap(euler.x), snap(euler.y), snap(euler.z)))
        }
        objects[index].rotation = newRotation
        rebuildGizmoBuffer()
    }
}

extension LevelViewerRenderer: GizmoInteractiveRenderer {}

// Was `private` — widened to file-default (internal) so `AnimationSkeletonBinding`
// (a separate file needing the exact same TRS-composition helper) can reuse
// it instead of a second, possibly-diverging copy.
extension simd_float4x4 {
    init(translation: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
    }
}
