import SwiftUI
import CTModels
import CTParsers
import CTExport
import simd

/// Phase 3.4 property inspectors: plain-language `Form`s over the raw
/// `Position`/`Instance`/`Trigger` records, so browsing the placement data
/// no longer means eyeballing hex. Read-only for now — there's no
/// write-back/repackage path wired to the UI yet, so these mirror
/// `MaterialInspectorView`/`TextureInspectorView` rather than promising
/// in-place editing.
/// "Editing GUI" proof of concept: the one record type in this build with
/// a real write path all the way through (see `WorldPlacementWriter`,
/// `WorkspaceViewModel.patchedFileBytes`). Every other inspector in this
/// file stays read-only — this one specifically demonstrates decode -> edit
/// -> encode -> patch -> save, not "editing everywhere now."
struct PositionInspectorView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let node: ChunkNode
    let position: PositionMarker

    @State private var x: String = ""
    @State private var y: String = ""
    @State private var z: String = ""
    @State private var w: String = ""
    @State private var isCrateSheetPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Point") {
                    LabeledContent("X") { TextField("X", text: $x).textFieldStyle(.roundedBorder) }
                    LabeledContent("Y") { TextField("Y", text: $y).textFieldStyle(.roundedBorder) }
                    LabeledContent("Z") { TextField("Z", text: $z).textFieldStyle(.roundedBorder) }
                    LabeledContent("W") { TextField("W", text: $w).textFieldStyle(.roundedBorder) }
                }
            }
            .formStyle(.grouped)
            .onAppear { loadFields() }
            .onChange(of: node.id) { _, _ in loadFields() }

            HStack {
                Button("Save Edited Copy…") { save() }
                    .disabled(editedPoint == nil || !workspace.canSaveEdits(for: node))
                Button("Export as Mod Crate…") { isCrateSheetPresented = true }
                    .disabled(editedPoint == nil || !workspace.canSaveEdits(for: node))
                Spacer()
            }
            .padding(.horizontal)

            if !workspace.canSaveEdits(for: node) {
                Text("Editing only saves for a standalone-opened .RM2/.SM2 file — this record's file is archive-packed, which this build doesn't have a write path for yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                Text("Saves an edited copy under a new name — the file you opened is never modified in place. \"Export as Mod Crate…\" packages the same edited bytes into a real CrateModLoader-installable .crate instead of a loose file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
        .sheet(isPresented: $isCrateSheetPresented) {
            if let patchedBytes = patchedBytesForCrate() {
                CrateExportSheet(node: node, patchedBytes: patchedBytes)
                    .environmentObject(workspace)
            }
        }
    }

    /// Re-derives the patched bytes on demand for the crate sheet — mirrors
    /// `save()`'s own encode-and-patch step rather than caching a stale copy
    /// from whenever the button was clicked, so editing the fields further
    /// while the sheet is closed is always reflected next time it opens.
    private func patchedBytesForCrate() -> Data? {
        guard let point = editedPoint else { return nil }
        let edited = PositionMarker(id: position.id, point: point)
        let encoded = WorldPlacementWriter.writePosition(edited)
        return workspace.patchedFileBytes(replacing: node, with: encoded)
    }

    private func loadFields() {
        x = String(position.point.x)
        y = String(position.point.y)
        z = String(position.point.z)
        w = String(position.point.w)
    }

    private var editedPoint: SIMD4<Float>? {
        guard let fx = Float(x), let fy = Float(y), let fz = Float(z), let fw = Float(w) else { return nil }
        return SIMD4(fx, fy, fz, fw)
    }

    private func save() {
        guard let point = editedPoint else { return }
        let edited = PositionMarker(id: position.id, point: point)
        let encoded = WorldPlacementWriter.writePosition(edited)
        guard let patchedBytes = workspace.patchedFileBytes(replacing: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(suggestedName: "\(node.displayName)_edited.rm2", message: "Save the edited copy of this file. The original file on disk is not modified.") else { return }
        do {
            try patchedBytes.write(to: url)
            workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent). The original file was not modified."
        } catch {
            workspace.lastError = "Save failed: \(error)"
        }
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
