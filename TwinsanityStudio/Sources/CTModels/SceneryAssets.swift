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

    /// Decomposes the full 4-row transform into position/rotation/scale,
    /// using the exact construction the reference tool's own working 3D
    /// viewer uses (`SMViewer.cs`/`RMViewer.cs` `LoadSceneryModel`) — this
    /// is a two-step construction, and an earlier version of this function
    /// (twice) got it wrong by only accounting for the first step:
    ///
    /// **Step 1** builds an OpenTK `Matrix4` (row-vector convention,
    /// `v' = v * M`) directly from the 4 on-disk rows `R0`/`R1`/`R2`/`R3`:
    /// ```
    /// M11=-R0.X  M12=R1.X  M13=R2.X  M14=R0.W
    /// M21=-R0.Y  M22=R1.Y  M23=R2.Y  M24=R1.W
    /// M31=-R0.Z  M32=R1.Z  M33=R2.Z  M34=R2.W
    /// M41=R3.X   M42=R3.Y  M43=R3.Z  M44=R3.W
    /// ```
    /// **Step 2**, easy to miss reading only the assembly above:
    /// `modelMatrix *= Matrix4.CreateScale(-1, 1, 1)`. Post-multiplying by
    /// `diag(-1,1,1,1)` negates only the matrix's *first column* — i.e.
    /// `M11`, `M21`, `M31`, `M41`. That cancels the `-R0.*` negation Step 1
    /// put into the rotation/scale block (`M11/M21/M31` go from `-R0.X/Y/Z`
    /// back to `+R0.X/Y/Z`) and instead negates the translation, `M41`
    /// (`R3.X` → `-R3.X`).
    ///
    /// Composing both steps, the rotation/scale block ends up as the
    /// **plain transpose** of the on-disk 3×3 block (no sign flip at all —
    /// row-vector-to-column-vector conversion is always a transpose, full
    /// stop), and only the translation's X component is negated. Every
    /// previous version of this function tried to hand-roll a sign flip
    /// into the rotation/scale columns (either copying whole rows, or
    /// negating row0's components) while leaving translation untouched —
    /// exactly backwards from what the reference tool actually does once
    /// both steps are accounted for.
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
