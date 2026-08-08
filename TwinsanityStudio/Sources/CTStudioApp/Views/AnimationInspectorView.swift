import SwiftUI
import CTModels

/// Shows decoded animation curve data with frame-scrubbing playback controls.
///
/// This intentionally stops at *data* playback (scrubbing through decoded
/// per-frame channel values) rather than driving a skinned mesh in the 3D
/// viewport: turning a frame's raw channel values into a final joint matrix
/// depends on `JointSettings.Flags`/`TransformationChoice` semantics that
/// aren't fully pinned down even in the reference tool (see
/// `AnimationViewer.AnimateSkeletonJointBuffer` in the original source) — so
/// rather than guess at a wrong skinning result, this exposes the real
/// decoded values for inspection/export instead.
struct AnimationInspectorView: View {
    let animation: AnimationAsset
    @State private var currentFrame: Double = 0
    @State private var isPlaying = false
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            trackSection(title: "Body Track", track: animation.body)
            if animation.facial.totalFrames > 0 {
                Divider()
                trackSection(title: "Facial Track", track: animation.facial)
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    @ViewBuilder
    private func trackSection(title: String, track: AnimationTrack) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Form {
                LabeledContent("Joints", value: "\(track.jointSettings.count)")
                LabeledContent("Static Transforms", value: "\(track.staticTransforms.count)")
                LabeledContent("Total Frames", value: "\(track.totalFrames)")
                LabeledContent("Components / Frame", value: "\(track.componentsPerFrame)")
            }
            .formStyle(.grouped)

            if track.totalFrames > 1 {
                HStack {
                    Button {
                        togglePlayback(track: track)
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                    Slider(value: $currentFrame, in: 0...Double(track.totalFrames - 1), step: 1)
                    Text("\(Int(currentFrame)) / \(track.totalFrames - 1)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                }

                let frameIndex = min(track.totalFrames - 1, max(0, Int(currentFrame)))
                let frame = track.frames[frameIndex]
                DisclosureGroup("Frame \(frameIndex) channel values (\(frame.values.count))") {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 4) {
                            ForEach(Array(frame.values.enumerated()), id: \.offset) { idx, value in
                                Text(String(format: "%.3f", Float(value) / 4096.0))
                                    .font(.system(.caption2, design: .monospaced))
                                    .padding(4)
                                    .background(Color.secondary.opacity(0.08))
                                    .cornerRadius(4)
                                    .help("Channel \(idx): raw \(value)")
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
    }

    private func togglePlayback(track: AnimationTrack) {
        isPlaying.toggle()
        if isPlaying {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
                currentFrame = (currentFrame + 1).truncatingRemainder(dividingBy: Double(max(1, track.totalFrames)))
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }
}
