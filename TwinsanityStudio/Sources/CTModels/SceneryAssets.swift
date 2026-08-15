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
    /// **This is the third and, as of a real, user-verified comparison
    /// against the actual reference tool's own live rendering (not just
    /// reading its source), final correction to this function's rotation
    /// handling.** The previous version's own doc comment worked through
    /// the reference's `LoadSceneryModel` (`SMViewer.cs`/`RMViewer.cs`)
    /// two-step matrix construction — row assembly, then a
    /// `Matrix4.CreateScale(-1,1,1)` post-multiply — and concluded the
    /// rotation/scale block needed a component-wise transpose of the
    /// on-disk 3×3 block. That derivation was internally self-consistent
    /// and reproduced the reference source's own arithmetic bit-for-bit by
    /// hand trace, which is exactly why it went unnoticed for as long as it
    /// did: matching source-code arithmetic isn't the same as matching
    /// real rendered output, and OpenTK's `Vector4 * Matrix4` operator's
    /// actual row-vector-vs-column-vector convention isn't settleable by
    /// reading this codebase alone. A user directly compared this app's
    /// rendering of a real, non-square, orientation-sensitive placement
    /// (`beach.sm2`, a floor/wall panel) against the real Twinsanity
    /// Editor running the *same file* and confirmed the reference shows it
    /// the other way around — the previous formula's rotation was exactly
    /// 180° off for asymmetric geometry (invisible on symmetric square
    /// tiles, which is why the extensive real-data position/edge-alignment
    /// regressions never caught it: rotating a placement 180° doesn't
    /// change whether its *position* lines up with a neighbor).
    ///
    /// The corrected formula is the on-disk 3×3 block used **directly**,
    /// column-for-row, with no transpose and no per-component sign flip —
    /// the algebraic transpose of the previous formula's rotation, which
    /// is exactly the 180°-equivalent correction (for a rotation matrix,
    /// transpose = inverse, and inverting a pure-axis rotation is a sign
    /// flip on that axis's angle). Re-verified against real data after
    /// this correction: the same real adjacent-tile-pair edge-alignment
    /// check this file's tests already used still passes (µm-scale gap,
    /// not degraded), confirming this isn't just "the opposite of wrong" —
    /// it's independently still geometrically consistent. Translation
    /// (`-row3.x`, unchanged otherwise) was never in question; every
    /// version of this function has agreed on it, and it's separately
    /// covered by `CoordinateSystemRegressionTests`.
    ///
    /// Scale is each column's length; dividing it out leaves a pure
    /// rotation matrix for `simd_quatf`.
    public var worldTransform: (position: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>)? {
        guard modelMatrix.count > 3 else { return nil }
        let row0 = modelMatrix[0]
        let row1 = modelMatrix[1]
        let row2 = modelMatrix[2]
        let row3 = modelMatrix[3]

        let col0 = SIMD3<Float>(row0.x, row0.y, row0.z)
        let col1 = SIMD3<Float>(row1.x, row1.y, row1.z)
        let col2 = SIMD3<Float>(row2.x, row2.y, row2.z)

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
