import Foundation

/// Per-joint indirection into either the static-value pool or the per-frame
/// animated-column pool (`Animation.JointSettings`,
/// `Twinsanity/Items/Code/Animation.cs:139-162`).
public struct AnimJointSettings: Sendable {
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
public struct AnimStaticTransform: Sendable {
    public var stored: Int16

    public init(stored: Int16) {
        self.stored = stored
    }

    public var linearValue: Float { Float(stored) / 4096.0 }
    public var rotationRadians: Float {
        (Float(stored) * 16) / Float(UInt16.max &+ 1) * .pi * 2
    }
}

/// One animated frame's flat channel row (`Animation.AnimatedTransform`). Each
/// joint's actual per-frame value is `values[jointSettings.animatedTransformIndex]`.
public struct AnimFrame: Sendable {
    public var values: [Int16]

    public init(values: [Int16]) {
        self.values = values
    }

    public func linearValue(at index: Int) -> Float { Float(values[index]) / 4096.0 }
}

/// One of the two independent curve sets in an `Animation` record (body,
/// facial) — see `Animation.cs:12-22`.
public struct AnimationTrack: Sendable {
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
public struct AnimationAsset: Sendable, Identifiable {
    public let id: UInt32
    public var body: AnimationTrack
    public var facial: AnimationTrack

    public init(id: UInt32, body: AnimationTrack, facial: AnimationTrack) {
        self.id = id
        self.body = body
        self.facial = facial
    }
}
