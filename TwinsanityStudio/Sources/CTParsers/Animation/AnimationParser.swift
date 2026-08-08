import Foundation
import CTCore
import CTModels

/// Decodes an `Animation` record — two independent curve tracks (body, then
/// facial), each a joint-indirection table over a shared static/animated
/// value pool. Ported from `Twinsanity/Items/Code/Animation.cs`.
public enum AnimationParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> AnimationAsset {
        let body = try readTrack(&cursor, requireNonEmpty: true)
        let facial = try readTrack(&cursor, requireNonEmpty: false)
        return AnimationAsset(id: recordID, body: body, facial: facial)
    }

    /// `requireNonEmpty` mirrors the original's asymmetry: the body track's
    /// packer/frame-count fields are always followed by data, but the facial
    /// track only actually has joint/transform/frame data when its computed
    /// `facialAnimationDataSize` is nonzero (`Animation.cs:104-131`) — some
    /// records carry a facial packer field that describes zero joints and no
    /// trailing data at all.
    private static func readTrack(_ cursor: inout BinaryCursor, requireNonEmpty: Bool) throws -> AnimationTrack {
        let packer = try cursor.readUInt32()
        let totalFrames = try cursor.readUInt16()

        let jointCount = Int(packer & 0x7F)
        let transformationCount = Int((packer >> 0xA) & 0xFFE) / 2
        let componentsPerFrame = Int(packer >> 0x16)

        let dataSize = jointCount * 8 + transformationCount * 2 + componentsPerFrame * Int(totalFrames) * 2
        guard requireNonEmpty || dataSize > 0 else {
            return AnimationTrack(jointSettings: [], staticTransforms: [], frames: [], componentsPerFrame: componentsPerFrame)
        }

        var jointSettings: [AnimJointSettings] = []
        jointSettings.reserveCapacity(jointCount)
        for _ in 0..<jointCount {
            jointSettings.append(AnimJointSettings(
                flags: try cursor.readUInt16(),
                transformationChoice: try cursor.readUInt16(),
                transformationIndex: try cursor.readUInt16(),
                animatedTransformIndex: try cursor.readUInt16()
            ))
        }

        var staticTransforms: [AnimStaticTransform] = []
        staticTransforms.reserveCapacity(transformationCount)
        for _ in 0..<transformationCount {
            staticTransforms.append(AnimStaticTransform(stored: try cursor.readInt16()))
        }

        var frames: [AnimFrame] = []
        frames.reserveCapacity(Int(totalFrames))
        for _ in 0..<totalFrames {
            var values: [Int16] = []
            values.reserveCapacity(componentsPerFrame)
            for _ in 0..<componentsPerFrame {
                values.append(try cursor.readInt16())
            }
            frames.append(AnimFrame(values: values))
        }

        return AnimationTrack(jointSettings: jointSettings, staticTransforms: staticTransforms, frames: frames, componentsPerFrame: componentsPerFrame)
    }
}
