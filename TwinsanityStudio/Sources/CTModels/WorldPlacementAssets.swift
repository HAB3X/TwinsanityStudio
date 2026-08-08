import Foundation
import simd

/// A named point in space (`Position` record, `SectionType.position`) —
/// referenced by ID from a `PlacedInstance`'s `childPositionIDs`/from path
/// data, with no data of its own beyond where it is. Ported from
/// `Twinsanity/Items/Instances/Position.cs`.
public struct PositionMarker: Sendable, Identifiable {
    public let id: UInt32
    public var point: SIMD4<Float>

    public init(id: UInt32, point: SIMD4<Float>) {
        self.id = id
        self.point = point
    }
}

/// A placed entity (`Instance` record, `SectionType.objectInstance`) — where
/// an `Object` (`objectID`, the game-logic definition of *what* this is)
/// sits in the world, plus the child instance/position/path records it owns.
/// Ported from `Twinsanity/Items/Instances/Instance.cs`.
public struct PlacedInstance: Sendable, Identifiable {
    public let id: UInt32
    public var position: SIMD4<Float>
    /// Raw 16-bit angle fractions of a full turn — see `PlacedInstance.degrees(fromRawAngle:)`.
    public var rotationRaw: SIMD3<UInt16>
    /// "Center of mass" rotation — same raw angle encoding as `rotationRaw`;
    /// the reference tool exposes both but doesn't document how the engine
    /// actually uses the distinction.
    public var comRotationRaw: SIMD3<UInt16>
    public var childInstanceIDs: [UInt16]
    public var childPositionIDs: [UInt16]
    public var childPathIDs: [UInt16]
    public var objectID: UInt16
    public var refList: Int16
    public var scriptID: Int16
    public var flags: UInt32
    /// Three genuinely undocumented data lists (`UnkI321`/`2`/`3` in the
    /// reference tool) — kept so the record round-trips losslessly, not
    /// because their meaning is known.
    public var unknownUInt32List: [UInt32]
    public var unknownFloatList: [Float]
    public var unknownUInt32List2: [UInt32]

    public init(
        id: UInt32,
        position: SIMD4<Float>,
        rotationRaw: SIMD3<UInt16>,
        comRotationRaw: SIMD3<UInt16>,
        childInstanceIDs: [UInt16],
        childPositionIDs: [UInt16],
        childPathIDs: [UInt16],
        objectID: UInt16,
        refList: Int16,
        scriptID: Int16,
        flags: UInt32,
        unknownUInt32List: [UInt32],
        unknownFloatList: [Float],
        unknownUInt32List2: [UInt32]
    ) {
        self.id = id
        self.position = position
        self.rotationRaw = rotationRaw
        self.comRotationRaw = comRotationRaw
        self.childInstanceIDs = childInstanceIDs
        self.childPositionIDs = childPositionIDs
        self.childPathIDs = childPathIDs
        self.objectID = objectID
        self.refList = refList
        self.scriptID = scriptID
        self.flags = flags
        self.unknownUInt32List = unknownUInt32List
        self.unknownFloatList = unknownFloatList
        self.unknownUInt32List2 = unknownUInt32List2
    }

    /// Converts a raw 16-bit angle to degrees the same way the reference
    /// tool's `InstanceEditor.cs` does (`raw / 65536 * 360`).
    public static func degrees(fromRawAngle raw: UInt16) -> Float {
        Float(raw) / Float(UInt32(UInt16.max) + 1) * 360
    }

    public var rotationDegrees: SIMD3<Float> {
        SIMD3(
            Self.degrees(fromRawAngle: rotationRaw.x),
            Self.degrees(fromRawAngle: rotationRaw.y),
            Self.degrees(fromRawAngle: rotationRaw.z)
        )
    }
}

/// A trigger volume (`Trigger` record, `SectionType.trigger`) — an oriented
/// box (quaternion rotation, position, size) that fires when something
/// enters it, plus up to 4 game-specific argument values and the instances
/// it references. Ported from `Twinsanity/Items/Instances/Trigger.cs`.
public struct TriggerVolume: Sendable, Identifiable {
    public let id: UInt32
    public var header: UInt32
    public var enabledMask: UInt32
    public var someFloat: Float
    /// `Coords[0]` on disk — a quaternion, not a raw XYZW vector (confirmed
    /// by the reference tool's `TriggerEditor.cs`, which recovers the angle
    /// via `acos(w)`).
    public var rotationQuaternion: SIMD4<Float>
    public var position: SIMD4<Float>
    public var size: SIMD4<Float>
    public var instanceIDs: [UInt16]
    public var arg1: UInt16
    public var arg2: UInt16
    public var arg3: UInt16
    public var arg4: UInt16

    public init(
        id: UInt32,
        header: UInt32,
        enabledMask: UInt32,
        someFloat: Float,
        rotationQuaternion: SIMD4<Float>,
        position: SIMD4<Float>,
        size: SIMD4<Float>,
        instanceIDs: [UInt16],
        arg1: UInt16,
        arg2: UInt16,
        arg3: UInt16,
        arg4: UInt16
    ) {
        self.id = id
        self.header = header
        self.enabledMask = enabledMask
        self.someFloat = someFloat
        self.rotationQuaternion = rotationQuaternion
        self.position = position
        self.size = size
        self.instanceIDs = instanceIDs
        self.arg1 = arg1
        self.arg2 = arg2
        self.arg3 = arg3
        self.arg4 = arg4
    }

    /// Rotation angle in degrees, decoded the same way as the reference
    /// tool's `TriggerEditor.cs` (`2 * acos(w)`) — display only; editing
    /// still round-trips through the raw quaternion.
    public var rotationAngleDegrees: Float {
        2 * acos(min(1, max(-1, rotationQuaternion.w))) * 180 / .pi
    }
}
