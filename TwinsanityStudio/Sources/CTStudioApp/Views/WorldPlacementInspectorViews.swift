import SwiftUI
import CTModels
import simd

/// Phase 3.4 property inspectors: plain-language `Form`s over the raw
/// `Position`/`Instance`/`Trigger` records, so browsing the placement data
/// no longer means eyeballing hex. Read-only for now — there's no
/// write-back/repackage path wired to the UI yet, so these mirror
/// `MaterialInspectorView`/`TextureInspectorView` rather than promising
/// in-place editing.
struct PositionInspectorView: View {
    let position: PositionMarker

    var body: some View {
        Form {
            LabeledContent("Point", value: vectorString(position.point))
        }
        .formStyle(.grouped)
    }
}

struct InstanceInspectorView: View {
    let instance: PlacedInstance

    var body: some View {
        Form {
            Section("Placement") {
                LabeledContent("Position", value: vectorString(instance.position))
                LabeledContent("Rotation", value: degreesString(instance.rotationDegrees))
                LabeledContent("COM Rotation", value: degreesString(SIMD3(
                    PlacedInstance.degrees(fromRawAngle: instance.comRotationRaw.x),
                    PlacedInstance.degrees(fromRawAngle: instance.comRotationRaw.y),
                    PlacedInstance.degrees(fromRawAngle: instance.comRotationRaw.z)
                )))
            }
            Section("Identity") {
                LabeledContent("Object ID", value: "\(instance.objectID)")
                LabeledContent("Script ID", value: instance.scriptID == -1 ? "None" : "\(instance.scriptID)")
                LabeledContent("Ref List", value: instance.refList == -1 ? "None" : "\(instance.refList)")
                LabeledContent("Flags", value: "0x\(String(instance.flags, radix: 16))")
            }
            if !instance.childInstanceIDs.isEmpty {
                Section("Child Instances (\(instance.childInstanceIDs.count))") {
                    idList(instance.childInstanceIDs)
                }
            }
            if !instance.childPositionIDs.isEmpty {
                Section("Referenced Positions (\(instance.childPositionIDs.count))") {
                    idList(instance.childPositionIDs)
                }
            }
            if !instance.childPathIDs.isEmpty {
                Section("Referenced Paths (\(instance.childPathIDs.count))") {
                    idList(instance.childPathIDs)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func idList(_ ids: [UInt16]) -> some View {
        Text(ids.map { "#\($0)" }.joined(separator: ", "))
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}

struct TriggerInspectorView: View {
    let trigger: TriggerVolume

    var body: some View {
        Form {
            Section("Volume") {
                LabeledContent("Position", value: vectorString(trigger.position))
                LabeledContent("Size", value: vectorString(trigger.size))
                LabeledContent("Rotation Angle", value: String(format: "%.1f°", trigger.rotationAngleDegrees))
                LabeledContent("Rotation Quaternion", value: vectorString(trigger.rotationQuaternion))
            }
            Section("Header") {
                LabeledContent("Header", value: "0x\(String(trigger.header, radix: 16))")
                LabeledContent("Enabled Mask", value: "0b\(String(trigger.enabledMask, radix: 2))")
                LabeledContent("Some Float", value: String(format: "%.3f", trigger.someFloat))
            }
            Section("Arguments") {
                LabeledContent("Arg 1", value: "\(trigger.arg1)")
                LabeledContent("Arg 2", value: "\(trigger.arg2)")
                LabeledContent("Arg 3", value: "\(trigger.arg3)")
                LabeledContent("Arg 4", value: "\(trigger.arg4)")
            }
            if !trigger.instanceIDs.isEmpty {
                Section("Referenced Instances (\(trigger.instanceIDs.count))") {
                    Text(trigger.instanceIDs.map { "#\($0)" }.joined(separator: ", "))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private func vectorString(_ v: SIMD4<Float>) -> String {
    String(format: "%.3f, %.3f, %.3f, %.3f", v.x, v.y, v.z, v.w)
}

private func degreesString(_ v: SIMD3<Float>) -> String {
    String(format: "%.1f°, %.1f°, %.1f°", v.x, v.y, v.z)
}
