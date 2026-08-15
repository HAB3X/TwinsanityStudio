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

    public init(modelID: UInt32, isSpecial: Bool, boundingBoxMin: SIMD4<Float>, boundingBoxMax: SIMD4<Float>, modelMatrix: [SIMD4<Float>]) {
        self.modelID = modelID
        self.isSpecial = isSpecial
        self.boundingBoxMin = boundingBoxMin
        self.boundingBoxMax = boundingBoxMax
        self.modelMatrix = modelMatrix
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

    public init(header: UInt32, placements: [SceneryModelPlacement]) {
        self.header = header
        self.placements = placements
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
/// (`LightAmbient`/`LightDirectional`/`LightPoint`/`LightNegative`) shares
/// this common shape; the reference tool's extra per-kind fields (facing
/// vectors, falloff shorts) aren't modeled here since nothing in this pass
/// renders lighting from level data yet — position/radius/color is enough
/// to place a marker in a future level viewport.
public struct SceneryLight: Sendable {
    public var radius: Float
    public var color: SIMD3<Float>
    public var position: SIMD4<Float>

    public init(radius: Float, color: SIMD3<Float>, position: SIMD4<Float>) {
        self.radius = radius
        self.color = color
        self.position = position
    }
}

/// A decoded `SceneryData` record (`Twinsanity/Items/SceneryData.cs`) — a
/// whole level's static scenery placement tree, plus its ambient/
/// directional/point/negative lights.
public struct SceneryAsset: Sendable, Identifiable {
    public let id: UInt32
    public var chunkName: String
    public var skydomeID: UInt32?
    public var ambientLights: [SceneryLight]
    public var directionalLights: [SceneryLight]
    public var pointLights: [SceneryLight]
    public var negativeLights: [SceneryLight]
    /// `nil` when this record's `HeaderUnk3 != 0x160A` — the reference
    /// tool leaves the whole tree unset in that case too.
    public var root: SceneryGroup?

    public init(id: UInt32, chunkName: String, skydomeID: UInt32?, ambientLights: [SceneryLight], directionalLights: [SceneryLight], pointLights: [SceneryLight], negativeLights: [SceneryLight], root: SceneryGroup?) {
        self.id = id
        self.chunkName = chunkName
        self.skydomeID = skydomeID
        self.ambientLights = ambientLights
        self.directionalLights = directionalLights
        self.pointLights = pointLights
        self.negativeLights = negativeLights
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
