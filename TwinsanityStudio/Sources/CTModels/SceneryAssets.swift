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
    /// viewer uses (`RMViewer.cs`/`SMViewer.cs` `LoadScenery`):
    /// ```
    /// M11=-R0.X  M12=R1.X  M13=R2.X  M14=R0.W
    /// M21=-R0.Y  M22=R1.Y  M23=R2.Y  M24=R1.W
    /// M31=-R0.Z  M32=R1.Z  M33=R2.Z  M34=R2.W
    /// M41=R3.X   M42=R3.Y  M43=R3.Z  M44=R3.W
    /// ```
    /// That matrix is built in the reference tool's row-vector convention
    /// (`v' = v * M`, so `M`'s *rows* are the transformed basis vectors —
    /// row 1 is where local +X goes, row 2 is local +Y, row 3 is local
    /// +Z). simd is column-vector (`v' = M * v`, basis vectors are
    /// *columns*), so converting requires a transpose: simd's column *j*
    /// must equal the reference's row *(j+1)*, not a straight copy of one
    /// input row. Concretely, column 0 (local +X, transformed) takes the
    /// X-component of `R0`/`R1`/`R2` — `(-R0.X, R1.X, R2.X)` — not all of
    /// `R0`. An earlier version of this function copied whole input rows
    /// into whole output columns instead of transposing, which happened to
    /// pass its own round-trip tests (encode and decode shared the same
    /// wrong formula) while producing wrong rotation/scale for any
    /// non-trivial transform against real game data — every placement's
    /// *position* (row 3, untouched by this bug either way) stayed
    /// correct, so the visible symptom was pieces correctly anchored but
    /// wildly mis-oriented/mis-scaled, reading as "flying apart."
    ///
    /// Scale is each corrected column's length; dividing it out leaves a
    /// pure rotation matrix for `simd_quatf`.
    public var worldTransform: (position: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>)? {
        guard modelMatrix.count > 3 else { return nil }
        let row0 = modelMatrix[0]
        let row1 = modelMatrix[1]
        let row2 = modelMatrix[2]
        let row3 = modelMatrix[3]

        let col0 = SIMD3<Float>(-row0.x, row1.x, row2.x)
        let col1 = SIMD3<Float>(-row0.y, row1.y, row2.y)
        let col2 = SIMD3<Float>(-row0.z, row1.z, row2.z)

        let scaleX = simd_length(col0)
        let scaleY = simd_length(col1)
        let scaleZ = simd_length(col2)

        let rotationMatrix = simd_float3x3(columns: (
            scaleX > 0.0001 ? col0 / scaleX : SIMD3<Float>(1, 0, 0),
            scaleY > 0.0001 ? col1 / scaleY : SIMD3<Float>(0, 1, 0),
            scaleZ > 0.0001 ? col2 / scaleZ : SIMD3<Float>(0, 0, 1)
        ))

        return (SIMD3(row3.x, row3.y, row3.z), simd_quatf(rotationMatrix), SIMD3(scaleX, scaleY, scaleZ))
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
