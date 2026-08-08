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

struct CameraInspectorView: View {
    let camera: PlacedCamera

    var body: some View {
        Form {
            Section("Volume") {
                LabeledContent("Position", value: vectorString(camera.position))
                LabeledContent("Size", value: vectorString(camera.size))
                LabeledContent("Rotation Angle", value: String(format: "%.1f°", camera.rotationAngleDegrees))
            }
            Section("Camera Types") {
                LabeledContent("Slot 1", value: camera.cameraType1.displayName)
                LabeledContent("Slot 2", value: camera.cameraType2.displayName)
            }
            if let subtype1 = camera.subtype1 {
                Section("Slot 1 Data") {
                    CameraSubtypeSummaryView(subtype: subtype1)
                }
            }
            if let subtype2 = camera.subtype2 {
                Section("Slot 2 Data") {
                    CameraSubtypeSummaryView(subtype: subtype2)
                }
            }
            if !camera.instanceIDs.isEmpty {
                Section("Referenced Instances (\(camera.instanceIDs.count))") {
                    Text(camera.instanceIDs.map { "#\($0)" }.joined(separator: ", "))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Section("Advanced / Undecoded") {
                DisclosureGroup("Header & Camera Fields") {
                    LabeledContent("Header", value: "0x\(String(camera.header, radix: 16))")
                    LabeledContent("Enabled Mask", value: "0b\(String(camera.enabledMask, radix: 2))")
                    LabeledContent("Cam Header", value: "0x\(String(camera.camHeader, radix: 16))")
                    LabeledContent("Coords 1", value: vectorString(camera.unkCoords1))
                    LabeledContent("Coords 2", value: vectorString(camera.unkCoords2))
                    Text("Every other field on this record is genuinely undocumented by the reference tool this was ported from — shown for completeness, not because its meaning is known.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Compact, per-subtype field summary — full raw byte-for-byte detail
/// (matrices, control-point arrays, undecoded trailing blobs) is available
/// but not exhaustively spelled out here; counts/sizes are shown instead of
/// dumping e.g. a Spline's full control-point list into a form.
private struct CameraSubtypeSummaryView: View {
    let subtype: CameraSubtype

    var body: some View {
        switch subtype {
        case .boss(let boss):
            LabeledContent("Vector", value: vectorString(boss.unkVector))
            LabeledContent("Floats", value: String(format: "%.2f, %.2f, %.2f, %.2f", boss.unkFloat3, boss.unkFloat4, boss.unkFloat5, boss.unkFloat6))
        case .point(let point):
            LabeledContent("Point", value: vectorString(point.unkVector))
        case .line(let line):
            LabeledContent("Box Min", value: vectorString(line.boundingBoxVector1))
            LabeledContent("Box Max", value: vectorString(line.boundingBoxVector2))
        case .path(let path):
            LabeledContent("Control Points", value: "\(path.unkVectors.count)")
            LabeledContent("Trailing Data", value: "\(path.trailingData.count) bytes")
        case .null1C05:
            Text("No payload for this sub-camera type.").foregroundStyle(.secondary)
        case .spline(let spline):
            LabeledContent("Segments", value: "\(spline.segmentCount)")
            LabeledContent("Control Points", value: "\(spline.unkVectors.count)")
            LabeledContent("Trailing Data", value: "\(spline.trailingData.count) bytes")
        case .unused1C09(let minor):
            LabeledContent("Floats", value: String(format: "%.2f, %.2f", minor.unkFloat1, minor.unkFloat2))
        case .point2(let point2):
            LabeledContent("Point", value: vectorString(point2.unkVector))
        case .unused1C0C(let bytes):
            LabeledContent("Bytes", value: "\(bytes.byte1), \(bytes.byte2), \(bytes.byte3), \(bytes.byte4)")
        case .line2(let line2):
            LabeledContent("Box Min", value: vectorString(line2.boundingBoxVector1))
            LabeledContent("Box Max", value: vectorString(line2.boundingBoxVector2))
        case .empty1C0E:
            Text("No payload for this sub-camera type.").foregroundStyle(.secondary)
        case .zone(let zone):
            LabeledContent("Data 1 Vectors", value: "\(zone.data1Vectors.count)")
            LabeledContent("Data 2 Vectors", value: "\(zone.data2Vectors.count)")
        }
    }
}

private func vectorString(_ v: SIMD4<Float>) -> String {
    String(format: "%.3f, %.3f, %.3f, %.3f", v.x, v.y, v.z, v.w)
}

private func degreesString(_ v: SIMD3<Float>) -> String {
    String(format: "%.1f°, %.1f°, %.1f°", v.x, v.y, v.z)
}
