import simd
import CTModels

/// **Experimental / best-effort only.** Neither reference source available
/// to this project documents what `AnimJointSettings.flags`/
/// `transformationChoice` actually select (which channel — translation,
/// rotation, scale, on which axis — a given joint animates on); only the
/// raw byte layout of the data is confirmed (see `AnimationAsset`'s doc
/// comments). Real skeletal deformation is blocked on that missing piece.
///
/// This function exists so the Animation Sandbox's transport controls
/// drive *something* visible instead of nothing: it takes each joint's
/// `animatedTransformIndex`-selected channel value for the given frame and
/// nudges the bind-pose joint position along X by that amount. That is a
/// guess, not a decode — the resulting motion is illustrative (something
/// visibly changes as you scrub/play) and should not be read as an
/// accurate reproduction of the original animation. Every call site that
/// uses this must say so in its own UI text, not just rely on this comment.
enum ExperimentalAnimationPose {
    static func jointSegments(skeleton: SkeletonAsset, track: AnimationTrack, frameIndex: Int) -> [(SIMD3<Float>, SIMD3<Float>)] {
        guard let root = skeleton.joints.first, track.frames.indices.contains(frameIndex) else { return [] }
        let frame = track.frames[frameIndex]

        func bindLocalPosition(_ joint: Joint) -> SIMD3<Float> {
            guard joint.matrix.count > 3 else { return .zero }
            let v = joint.matrix[3]
            return SIMD3<Float>(v.x, v.y, v.z)
        }

        func experimentalLocalPosition(_ joint: Joint, jointArrayIndex: Int) -> SIMD3<Float> {
            var position = bindLocalPosition(joint)
            guard jointArrayIndex < track.jointSettings.count else { return position }
            let settings = track.jointSettings[jointArrayIndex]
            let channel = Int(settings.animatedTransformIndex)
            guard channel < frame.values.count else { return position }
            position.x += frame.linearValue(at: channel)
            return position
        }

        var worldPositions: [UInt32: SIMD3<Float>] = [root.jointIndex: experimentalLocalPosition(root, jointArrayIndex: 0)]
        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        for (index, joint) in skeleton.joints.enumerated() where index > 0 {
            let parentPos = worldPositions[joint.parentJointIndex] ?? .zero
            let pos = parentPos + experimentalLocalPosition(joint, jointArrayIndex: index)
            worldPositions[joint.jointIndex] = pos
            segments.append((parentPos, pos))
        }
        return segments
    }
}
