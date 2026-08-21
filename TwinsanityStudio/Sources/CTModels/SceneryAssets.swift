import Foundation
import simd

/// One placed scenery model, ported from the reference tool's
/// `SceneryData.ScenerySubModel` (`Twinsanity/Items/SceneryData.cs`).
/// `modelMatrix` is empty when its enclosing `SceneryModelGroup.header`
/// wasn't `0x1613` (the reference tool only reads matrices/IDs under that
/// header — see `LoadSceneryModel`).
public struct SceneryModelPlacement: Sendable {
    public var modelID: UInt32
    public var isSpecial: Bool
    public var boundingBoxMin: SIMD4<Float>
    public var boundingBoxMax: SIMD4<Float>
    /// 4 rows — a full affine transform for this placement.
    public var modelMatrix: [SIMD4<Float>]
    /// Byte offset of this placement's own 4-row `modelMatrix` block,
    /// relative to the enclosing `SceneryData` record's own start (same
    /// convention as `cameraControlPointFileOffset`: combine with the
    /// record's `ChunkNode.fileOffset` for an absolute file position).
    /// `nil` for a placement not parsed from a real record with tracked
    /// offsets (e.g. a hand-built value in a test). This is what makes
    /// "move an existing scenery placement, save" possible without
    /// re-encoding the whole (large, deeply nested) `SceneryData` tree --
    /// same "patch just the known-size field that changed" pattern this
    /// codebase already uses for `Position`/`Instance`/camera control
    /// points, not a claim that *creating a new* placement is supported
    /// (that needs real insertion into the nested group tree, which
    /// isn't built yet).
    public var matrixFileOffset: Int?

    public init(modelID: UInt32, isSpecial: Bool, boundingBoxMin: SIMD4<Float>, boundingBoxMax: SIMD4<Float>, modelMatrix: [SIMD4<Float>], matrixFileOffset: Int? = nil) {
        self.modelID = modelID
        self.isSpecial = isSpecial
        self.boundingBoxMin = boundingBoxMin
        self.boundingBoxMax = boundingBoxMax
        self.modelMatrix = modelMatrix
        self.matrixFileOffset = matrixFileOffset
    }

    /// Row 3 of the matrix is the translation column in every other 4-row
    /// transform this codebase decodes (`Joint.matrix`, `SkinTransform`) —
    /// used for a first-pass "where is this roughly" placement position
    /// without needing full matrix math wired through the renderer yet.
    public var translation: SIMD3<Float>? {
        guard modelMatrix.count > 3 else { return nil }
        let v = modelMatrix[3]
        return SIMD3(v.x, v.y, v.z)
    }

    /// Decomposes the full 4-row transform into position/rotation/scale.
    ///
    /// **Fourth correction to this function's rotation handling — this one
    /// grounded in reading OpenTK's actual `Vector4`/`Matrix4` operator
    /// source, not hand-tracing/assuming its convention.** Every earlier
    /// attempt (see git history / this file's prior revisions) got as far
    /// as correctly hand-tracing `LoadSceneryModel`'s (`SMViewer.cs`/
    /// `RMViewer.cs`) two-step matrix construction — row assembly with
    /// `row0` negated per-component, then a `Matrix4.CreateScale(-1,1,1)`
    /// post-multiply — and stopped there, since that construction alone
    /// *looks* fully sufficient to derive the answer. It isn't: it only
    /// tells you what bytes end up in OpenTK's `Matrix4`, not how that
    /// matrix actually gets applied to a vertex, and those two things use
    /// *different* row/column conventions in this specific library.
    ///
    /// Working through the construction (verified against the live
    /// `opentk/opentk` 3.x source, not recalled from memory): after both
    /// steps, OpenTK's `modelMatrix` ends up with **columns** equal to the
    /// on-disk rows (`Column0 = row0`, `Column1 = row1`, `Column2 = row2`)
    /// — i.e. numerically the transpose of the on-disk 3×3 block. That's
    /// exactly what the *previous* version of this function built via
    /// `simd_float3x3(columns: (row0, row1, row2))`, and exactly why it
    /// looked so thoroughly verified (it correctly reproduces OpenTK's own
    /// matrix, bit for bit) while still being wrong.
    ///
    /// The missing piece: `SMViewer.cs` transforms each vertex with
    /// `vertexPos *= modelMatrix` — `Vector4 operator*(Vector4, Matrix4)`,
    /// which OpenTK's own source implements as **row-vector** multiply
    /// (`result = vec * mat`, dotting `vec` against `mat`'s *columns*), not
    /// `Matrix4 * Vector4`'s column-vector form (OpenTK ships both, with
    /// different math — the ambiguity a previous version of this comment
    /// correctly flagged as unresolvable from reading only the call site).
    /// simd's `matrix * vector` is always column-vector. Porting a
    /// row-vector transform into a column-vector system needs one more
    /// transpose to compensate — and that transpose exactly cancels the
    /// one already baked into OpenTK's own matrix, leaving the correct
    /// simd matrix equal to **the on-disk 3×3 block, used directly,
    /// unchanged** (working the full vertex transform through by hand:
    /// `world.x = dot(local, row0) - row3.x`, `world.y = dot(local, row1)
    /// + row3.y`, `world.z = dot(local, row2) + row3.z` — i.e. row0/1/2
    /// used as the *rows* of the effective world matrix, not its columns).
    ///
    /// Real-data support: across many real same-model, genuinely-rotated
    /// placement pairs in `beach.sm2`, this formula's edge-alignment rate
    /// is the best of every candidate tried (including the previous,
    /// transpose-based one) — see this file's own investigation history.
    /// It is **not** claimed to be the final word on its own; symmetric/
    /// square geometry and 180°-symmetric shapes are structurally blind to
    /// several classes of rotation error (a lesson this function has
    /// already taught twice), so the real confirmation is checking several
    /// different floor/wall placements — not just one — against the live
    /// reference tool.
    ///
    /// Translation (`-row3.x`, unchanged otherwise) was never in question;
    /// every version of this function has agreed on it.
    ///
    /// Scale is each column's length; dividing it out leaves a pure
    /// rotation matrix for `simd_quatf`.
    public var worldTransform: (position: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>)? {
        guard modelMatrix.count > 3 else { return nil }
        let row0 = modelMatrix[0]
        let row1 = modelMatrix[1]
        let row2 = modelMatrix[2]
        let row3 = modelMatrix[3]

        let col0 = SIMD3<Float>(row0.x, row1.x, row2.x)
        let col1 = SIMD3<Float>(row0.y, row1.y, row2.y)
        let col2 = SIMD3<Float>(row0.z, row1.z, row2.z)

        let scaleX = simd_length(col0)
        let scaleY = simd_length(col1)
        let scaleZ = simd_length(col2)

        let rotationMatrix = simd_float3x3(columns: (
            scaleX > 0.0001 ? col0 / scaleX : SIMD3<Float>(1, 0, 0),
            scaleY > 0.0001 ? col1 / scaleY : SIMD3<Float>(0, 1, 0),
            scaleZ > 0.0001 ? col2 / scaleZ : SIMD3<Float>(0, 0, 1)
        ))

        return (SIMD3(-row3.x, row3.y, row3.z), simd_quatf(rotationMatrix), SIMD3(scaleX, scaleY, scaleZ))
    }
}

/// A `SceneryModelStruct` — a group of placements sharing one header/type
/// tag, plus the group's own bounding info.
public struct SceneryModelGroup: Sendable {
    public var header: UInt32
    public var placements: [SceneryModelPlacement]
    /// `SceneryModelStruct.UnkPos[5]` — 5 real, always-present `Vector4`s
    /// (`SceneryDataParser`'s own doc comment: "always present, unused by
    /// this reader") trailing every model group regardless of `header`.
    /// Kept so `SceneryDataWriter` can round-trip a group losslessly —
    /// without this, re-encoding *any* group (even one with no placement
    /// changes) would silently zero 80 real bytes.
    public var unkPos: [SIMD4<Float>]

    public init(header: UInt32, placements: [SceneryModelPlacement], unkPos: [SIMD4<Float>] = Array(repeating: .zero, count: 5)) {
        self.header = header
        self.placements = placements
        self.unkPos = unkPos
    }
}

/// A node in the recursive scenery placement tree (`SceneryStruct`) — up to
/// 8 child links, each either a nested group, a leaf model group, or empty,
/// selected by a type tag read just ahead of the link contents
/// (`LoadScenery`: `0x1600` = nested group, `0x1605` = leaf model group,
/// anything else = empty).
public indirect enum SceneryLink: Sendable {
    case group(SceneryGroup)
    case modelGroup(SceneryModelGroup)
    case empty
}

public struct SceneryGroup: Sendable {
    public var model: SceneryModelGroup
    public var links: [SceneryLink]

    public init(model: SceneryModelGroup, links: [SceneryLink]) {
        self.model = model
        self.links = links
    }

    /// Flattens the whole recursive tree into every placement with an
    /// actual transform — what a level-assembly viewport actually needs to
    /// draw, without the caller having to walk the tree itself.
    public func flattenedPlacements() -> [SceneryModelPlacement] {
        var result = model.placements
        for link in links {
            switch link {
            case .group(let child): result.append(contentsOf: child.flattenedPlacements())
            case .modelGroup(let group): result.append(contentsOf: group.placements)
            case .empty: break
            }
        }
        return result
    }
}

/// A single light entry — every one of `SceneryData`'s 4 light kinds
/// (`LightAmbient`/`LightDirectional`/`LightPoint`/`LightNegative`, each a
/// subclass of the reference's own `LightBase` in `SceneryData.cs`) shares
/// this one flat shape now, superset of every kind's fields — which of the
/// extra fields (`vector3`/`unkShort`/`unkFloat1`/`2`/`unkUInt1`/`2`/
/// `unkUShort1`/`2`) actually get written back out is determined purely by
/// *which array* a light is stored in (`SceneryAsset.directionalLights`
/// writes `vector3`+`unkShort`, `.pointLights` writes only `unkShort`,
/// `.negativeLights` writes `vector3` plus all 6 remaining unk fields,
/// `.ambientLights` writes none of them) — see `SceneryDataWriter`.
/// Real fields kept for round-tripping even though nothing in this pass
/// renders lighting from level data yet.
public struct SceneryLight: Sendable {
    public var flagsRaw: UInt32
    public var radius: Float
    public var colorR: Float
    public var colorG: Float
    public var colorB: Float
    public var colorUnk: Float
    public var position: SIMD4<Float>
    public var vector1: SIMD4<Float>
    public var vector2: SIMD4<Float>
    /// Directional/Negative only.
    public var vector3: SIMD4<Float>
    /// Directional/Point only.
    public var unkShort: UInt16
    /// Negative only.
    public var unkFloat1: Float
    public var unkFloat2: Float
    public var unkUInt1: UInt32
    public var unkUInt2: UInt32
    public var unkUShort1: UInt16
    public var unkUShort2: UInt16

    public init(
        flagsRaw: UInt32 = 0, radius: Float, colorR: Float, colorG: Float, colorB: Float, colorUnk: Float = 0,
        position: SIMD4<Float>, vector1: SIMD4<Float> = .zero, vector2: SIMD4<Float> = .zero,
        vector3: SIMD4<Float> = .zero, unkShort: UInt16 = 0,
        unkFloat1: Float = 0, unkFloat2: Float = 0, unkUInt1: UInt32 = 0, unkUInt2: UInt32 = 0,
        unkUShort1: UInt16 = 0, unkUShort2: UInt16 = 0
    ) {
        self.flagsRaw = flagsRaw
        self.radius = radius
        self.colorR = colorR
        self.colorG = colorG
        self.colorB = colorB
        self.colorUnk = colorUnk
        self.position = position
        self.vector1 = vector1
        self.vector2 = vector2
        self.vector3 = vector3
        self.unkShort = unkShort
        self.unkFloat1 = unkFloat1
        self.unkFloat2 = unkFloat2
        self.unkUInt1 = unkUInt1
        self.unkUInt2 = unkUInt2
        self.unkUShort1 = unkUShort1
        self.unkUShort2 = unkUShort2
    }

    /// Convenience view for existing display code — real `Color_R/G/B`
    /// packed into one vector, same as this type exposed before it grew
    /// the rest of its real fields.
    public var color: SIMD3<Float> {
        get { SIMD3(colorR, colorG, colorB) }
        set { colorR = newValue.x; colorG = newValue.y; colorB = newValue.z }
    }
}

/// A decoded `SceneryData` record (`Twinsanity/Items/SceneryData.cs`) — a
/// whole level's static scenery placement tree, plus its ambient/
/// directional/point/negative lights.
public struct SceneryAsset: Sendable, Identifiable {
    public let id: UInt32
    /// Real opaque bitfield (`HeaderUnk1`) — bit `0x10000` gates
    /// `skydomeID`, bit `0x20000` gates `headerBuffer`/lights. Kept as the
    /// real raw value (not just those two derived bools) since unknown
    /// other bits may be set in real data and must round-trip untouched.
    public var headerUnk1: UInt32
    public var chunkName: String
    public var headerUnk2: UInt32
    /// `HeaderUnk3` — gates whether `root`/`unkVar5` are present at all
    /// (`== 0x160A`). Kept raw for the same reason as `headerUnk1`.
    public var headerUnk3: UInt32
    public var headerUnk4: UInt8
    /// Whether this record's own file is a MonkeyBall-variant build —
    /// gates 3 extra zero bytes right after `headerUnk2` on both read and
    /// write (`SceneryData.cs`'s own `IsMonkeyBall`, set by the *caller*
    /// before parsing based on which file kind this came from). This
    /// package doesn't currently distinguish that file kind at the
    /// dispatch level (see `SceneryDataParser`'s own doc comment), so this
    /// is always `false` for anything actually parsed by this build.
    public var isMonkeyBall: Bool
    public var skydomeID: UInt32?
    /// `HeaderBuffer` — real, fixed 0x400-byte opaque block, present only
    /// when `headerUnk1 & 0x20000 != 0`. Never interpreted, only
    /// round-tripped.
    public var headerBuffer: Data?
    public var ambientLights: [SceneryLight]
    public var directionalLights: [SceneryLight]
    public var pointLights: [SceneryLight]
    public var negativeLights: [SceneryLight]
    /// Present only alongside `root` (both gated by `headerUnk3 == 0x160A`).
    public var unkVar5: UInt32?
    /// `nil` when this record's `HeaderUnk3 != 0x160A` — the reference
    /// tool leaves the whole tree unset in that case too.
    public var root: SceneryGroup?

    public init(
        id: UInt32, headerUnk1: UInt32 = 0, chunkName: String, headerUnk2: UInt32 = 0, headerUnk3: UInt32 = 0x160A,
        headerUnk4: UInt8 = 0, isMonkeyBall: Bool = false, skydomeID: UInt32?, headerBuffer: Data? = nil,
        ambientLights: [SceneryLight], directionalLights: [SceneryLight], pointLights: [SceneryLight], negativeLights: [SceneryLight],
        unkVar5: UInt32? = nil, root: SceneryGroup?
    ) {
        self.id = id
        self.headerUnk1 = headerUnk1
        self.chunkName = chunkName
        self.headerUnk2 = headerUnk2
        self.headerUnk3 = headerUnk3
        self.headerUnk4 = headerUnk4
        self.isMonkeyBall = isMonkeyBall
        self.skydomeID = skydomeID
        self.headerBuffer = headerBuffer
        self.ambientLights = ambientLights
        self.directionalLights = directionalLights
        self.pointLights = pointLights
        self.negativeLights = negativeLights
        self.unkVar5 = unkVar5
        self.root = root
    }

    public var placements: [SceneryModelPlacement] { root?.flattenedPlacements() ?? [] }
}

/// One `DynamicSceneryData` entry (`Twinsanity/Items/DynamicSceneryData.cs`)
/// — a movable/animated scenery piece (elevators, rotating platforms, ...).
/// Only its *resting* placement is exposed: `worldPosition`/
/// `worldRotation` are the reference tool's own reconciliation of "static
/// value if this channel doesn't animate, else the first keyframe" — full
/// per-frame motion curves aren't modeled, since nothing renders scenery
/// animation yet (see `DynamicSceneryDataParser` for exactly what's parsed
/// vs. discarded to reach this).
public struct DynamicSceneryPlacement: Sendable {
    public var modelID: UInt32
    public var boundingBoxMin: SIMD4<Float>
    public var boundingBoxMax: SIMD4<Float>
    public var worldPosition: SIMD3<Float>
    public var worldRotation: SIMD4<Float>

    public init(modelID: UInt32, boundingBoxMin: SIMD4<Float>, boundingBoxMax: SIMD4<Float>, worldPosition: SIMD3<Float>, worldRotation: SIMD4<Float>) {
        self.modelID = modelID
        self.boundingBoxMin = boundingBoxMin
        self.boundingBoxMax = boundingBoxMax
        self.worldPosition = worldPosition
        self.worldRotation = worldRotation
    }
}

public struct DynamicSceneryAsset: Sendable, Identifiable {
    public let id: UInt32
    public var placements: [DynamicSceneryPlacement]

    public init(id: UInt32, placements: [DynamicSceneryPlacement]) {
        self.id = id
        self.placements = placements
    }
}
