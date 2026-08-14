import Foundation

/// Per-joint indirection into either the static-value pool or the per-frame
/// animated-column pool (`Animation.JointSettings`,
/// `Twinsanity/Items/Code/Animation.cs:139-162`).
public struct AnimJointSettings: Sendable, Codable {
    public var flags: UInt16
    public var transformationChoice: UInt16
    public var transformationIndex: UInt16
    public var animatedTransformIndex: UInt16

    public init(flags: UInt16, transformationChoice: UInt16, transformationIndex: UInt16, animatedTransformIndex: UInt16) {
        self.flags = flags
        self.transformationChoice = transformationChoice
        self.transformationIndex = transformationIndex
        self.animatedTransformIndex = animatedTransformIndex
    }
}

/// A single fixed-point value shared by every frame (a joint that doesn't
/// animate on this channel). Translation/scale decode as Q12 fixed point
/// (`/ 4096`); rotation decodes on a different fixed-point scale mapping the
/// full `int16` range to one full turn (`Animation.Transformation.RotValue`,
/// `Animation.cs:180-186`).
public struct AnimStaticTransform: Sendable, Codable {
    public var stored: Int16

    public init(stored: Int16) {
        self.stored = stored
    }

    public var linearValue: Float { Float(stored) / 4096.0 }
    /// Real, previously-broken bug: `UInt16.max &+ 1` performs *wrapping*
    /// addition within `UInt16` itself (Swift has no automatic integer
    /// promotion the way C#'s `ushort.MaxValue + 1` gets promoted to `int`
    /// before adding) — `65535 &+ 1` overflows to `0`, not `65536`,
    /// silently turning this into a division by zero. Any nonzero `stored`
    /// value then produced `±Infinity` radians, and `simd_quatf(angle:
    /// .infinity, ...)`'s `sin`/`cos` of an infinite angle is `NaN` —
    /// poisoning that joint's rotation, and by extension (through the
    /// parent-chain composition in `AnimationSkeletonBinding.
    /// animatedWorldTransforms`) every one of its descendants too, for
    /// every joint whose rotation channel happened to be in this
    /// "static/frame-invariant" pool rather than the per-frame animated
    /// one — which real data does constantly (a joint that doesn't rotate
    /// on a given clip still gets a `Transformation` entry here, not a
    /// zero). This is likely the actual root cause of "animation playback
    /// distorts/scrunches the model and it doesn't move": a `NaN`-poisoned
    /// pose is identical every frame (`NaN` in, `NaN` out, regardless of
    /// which frame's translation/scale data is otherwise genuinely
    /// varying), reading as "frozen in a broken shape."
    public var rotationRadians: Float {
        (Float(stored) * 16) / (Float(UInt16.max) + 1) * .pi * 2
    }
}

/// One animated frame's flat channel row (`Animation.AnimatedTransform`). Each
/// joint's actual per-frame value is `values[jointSettings.animatedTransformIndex]`.
public struct AnimFrame: Sendable, Codable {
    public var values: [Int16]

    public init(values: [Int16]) {
        self.values = values
    }

    public func linearValue(at index: Int) -> Float { Float(values[index]) / 4096.0 }
}

/// One of the two independent curve sets in an `Animation` record (body,
/// facial) — see `Animation.cs:12-22`.
public struct AnimationTrack: Sendable, Codable {
    public var jointSettings: [AnimJointSettings]
    public var staticTransforms: [AnimStaticTransform]
    public var frames: [AnimFrame]
    public var componentsPerFrame: Int

    public init(jointSettings: [AnimJointSettings], staticTransforms: [AnimStaticTransform], frames: [AnimFrame], componentsPerFrame: Int) {
        self.jointSettings = jointSettings
        self.staticTransforms = staticTransforms
        self.frames = frames
        self.componentsPerFrame = componentsPerFrame
    }

    public var totalFrames: Int { frames.count }
}

/// A fully decoded `Animation` record: body + facial tracks.
public struct AnimationAsset: Sendable, Identifiable, Codable {
    public let id: UInt32
    public var body: AnimationTrack
    public var facial: AnimationTrack

    public init(id: UInt32, body: AnimationTrack, facial: AnimationTrack) {
        self.id = id
        self.body = body
        self.facial = facial
    }
}
