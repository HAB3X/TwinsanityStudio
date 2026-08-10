import SwiftUI
import CTModels
import CTParsers

/// Write-back editor for a decoded `ParticleData` record — ports
/// `Editors/ParticlesEditor.cs`'s field set for the scalar fields (every
/// `numericUpDown`-bound field the reference exposes). The reference's own
/// 8-entry gradient curves (color/alpha/size/rotation/collision) are
/// edited there via a dedicated curve-graph control this build doesn't
/// have yet — shown read-only here rather than as 100+ flat number
/// fields. List counts (definitions/instances) are fixed by the record's
/// on-disk size, same constraint as every other editor in this app.
struct ParticleDataEditorSheet: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let original: ParticleDataAsset

    @State private var particleTypes: [ParticleSystemDefinition]
    @State private var particleInstances: [ParticleSystemInstance]
    @State private var selectedDefinitionIndex = 0
    @State private var selectedInstanceIndex = 0
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, particleData: ParticleDataAsset) {
        self.node = node
        self.original = particleData
        _particleTypes = State(initialValue: particleData.particleTypes)
        _particleInstances = State(initialValue: particleData.particleInstances)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Particle Data #\(original.id)").font(.title3.bold())
            Text("Gradient curves (color/alpha/size/rotation/collision) round-trip unchanged — this build doesn't have a curve editor yet.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !particleTypes.isEmpty {
                Picker("Type", selection: $selectedDefinitionIndex) {
                    ForEach(particleTypes.indices, id: \.self) { i in
                        Text(particleTypes[i].name.isEmpty ? "Type \(i)" : particleTypes[i].name).tag(i)
                    }
                }
                ScrollView {
                    DefinitionFields(definition: $particleTypes[selectedDefinitionIndex])
                }
                .frame(maxHeight: 360)
            }

            if !particleInstances.isEmpty {
                Picker("Instance", selection: $selectedInstanceIndex) {
                    ForEach(particleInstances.indices, id: \.self) { i in
                        Text(particleInstances[i].name.isEmpty ? "Instance \(i)" : particleInstances[i].name).tag(i)
                    }
                }
                InstanceFields(instance: $particleInstances[selectedInstanceIndex])
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isSaving ? "Saving…" : "Save Edited Copy…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 520)
    }

    private func save() {
        errorMessage = nil
        var edited = original
        edited.particleTypes = particleTypes
        edited.particleInstances = particleInstances

        let encoded: Data
        do {
            encoded = try ParticleDataWriter.write(edited)
        } catch {
            errorMessage = "\(error)"
            return
        }
        guard let patchedBytes = workspace.patchedFileBytes(replacing: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this particle data changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this particle data changed. The original file was not modified."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}

private struct DefinitionFields: View {
    @Binding var definition: ParticleSystemDefinition

    var body: some View {
        Form {
            Section("Emission") {
                LabeledField("Gen Rate", value: Binding(get: { Double(definition.genRate) }, set: { definition.genRate = Int16($0) }))
                LabeledField("Max Particle Count", value: Binding(get: { Double(definition.maxParticleCount) }, set: { definition.maxParticleCount = UInt16(max(0, $0)) }))
                LabeledField("Emitter Over Time", value: Binding(get: { Double(definition.emitterOverTime) }, set: { definition.emitterOverTime = UInt16(max(0, $0)) }))
                LabeledField("Emitter Over Time Random", value: Binding(get: { Double(definition.emitterOverTimeRandom) }, set: { definition.emitterOverTimeRandom = UInt16(max(0, $0)) }))
                LabeledField("Emitter Off Time", value: Binding(get: { Double(definition.emitterOffTime) }, set: { definition.emitterOffTime = UInt16(max(0, $0)) }))
                LabeledField("Emitter Off Time Random", value: Binding(get: { Double(definition.emitterOffTimeRandom) }, set: { definition.emitterOffTimeRandom = UInt16(max(0, $0)) }))
            }
            Section("Motion") {
                LabeledField("Velocity", value: $definition.velocity)
                LabeledField("Random Emit X", value: $definition.randomEmitX)
                LabeledField("Random Emit Y", value: $definition.randomEmitY)
                LabeledField("Random Emit Z", value: $definition.randomEmitZ)
                LabeledField("Random Start X", value: $definition.randomStartX)
                LabeledField("Random Start Y", value: $definition.randomStartY)
                LabeledField("Random Start Z", value: $definition.randomStartZ)
                LabeledField("Gravity", value: $definition.gravity)
                LabeledField("Particle Life Time", value: $definition.particleLifeTime)
            }
            Section("Appearance") {
                LabeledField("Min Size", value: $definition.minSize)
                LabeledField("Max Size", value: $definition.maxSize)
                LabeledField("Min Rotation", value: $definition.minRotation)
                LabeledField("Max Rotation", value: $definition.maxRotation)
                LabeledField("Distortion X", value: $definition.distortionX)
                LabeledField("Distortion Y", value: $definition.distortionY)
                LabeledField("Scale Factor", value: $definition.scaleFactor)
            }
            Section("Radius / Draw") {
                LabeledField("Cut On Radius", value: $definition.cutOnRadius)
                LabeledField("Cut Off Radius", value: $definition.cutOffRadius)
                LabeledField("Draw Cut Off", value: $definition.drawCutOff)
                LabeledField("Texture Page", value: Binding(get: { Double(definition.texturePage) }, set: { definition.texturePage = Int32($0) }))
            }
            Section("Ghosts / Star Radial / Ramp") {
                LabeledField("Ghosts Num", value: Binding(get: { Double(definition.particleGhostsNum) }, set: { definition.particleGhostsNum = Int16($0) }))
                LabeledField("Ghost Separation", value: $definition.ghostSeparation)
                LabeledField("Star Radial Points", value: Binding(get: { Double(definition.starRadialPoints) }, set: { definition.starRadialPoints = Int16($0) }))
                LabeledField("Star Radius Ratio", value: $definition.starRadiusRatio)
                LabeledField("Ramp Time", value: $definition.rampTime)
            }
            Section("Jibber") {
                LabeledField("Jibber X Freq", value: $definition.jibberXFreq)
                LabeledField("Jibber X Amp", value: $definition.jibberXAmp)
                LabeledField("Jibber Y Freq", value: $definition.jibberYFreq)
                LabeledField("Jibber Y Amp", value: $definition.jibberYAmp)
            }
            Section("Collision") {
                LabeledField("Collision Num Spheres", value: Binding(get: { Double(definition.collisionNumSpheres) }, set: { definition.collisionNumSpheres = UInt8(max(0, min(255, $0))) }))
            }
        }
        .formStyle(.grouped)
    }
}

private struct InstanceFields: View {
    @Binding var instance: ParticleSystemInstance

    var body: some View {
        Form {
            LabeledField("Position X", value: Binding(get: { Double(instance.position.x) }, set: { instance.position.x = Float($0) }))
            LabeledField("Position Y", value: Binding(get: { Double(instance.position.y) }, set: { instance.position.y = Float($0) }))
            LabeledField("Position Z", value: Binding(get: { Double(instance.position.z) }, set: { instance.position.z = Float($0) }))
            LabeledField("Switch Value", value: $instance.switchValue)
            LabeledField("Plane Offset", value: $instance.planeOffset)
            LabeledField("Bounce Factor", value: $instance.bounceFactor)
            LabeledField("Group ID", value: Binding(get: { Double(instance.groupID) }, set: { instance.groupID = Int16($0) }))
        }
        .formStyle(.grouped)
    }
}

/// A `TextField` bound to a `Double`, with tolerant text parsing — every
/// numeric field in this editor funnels through here rather than
/// hand-rolling a `TextField<->String<->Numeric` conversion per field.
private struct LabeledField: View {
    let label: String
    @Binding var value: Double
    @State private var text: String = ""

    init(_ label: String, value: Binding<Double>) {
        self.label = label
        self._value = value
    }

    init(_ label: String, value: Binding<Float>) {
        self.label = label
        self._value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Float($0) })
    }

    var body: some View {
        LabeledContent(label) {
            TextField("value", text: $text)
                .textFieldStyle(.roundedBorder)
                .onAppear { text = Self.format(value) }
                .onChange(of: value) { _, newValue in text = Self.format(newValue) }
                .onSubmit { commit() }
                .onChange(of: text) { _, _ in commit() }
        }
    }

    private func commit() {
        if let parsed = Double(text) { value = parsed }
    }

    private static func format(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int64(v)) : "\(v)"
    }
}
