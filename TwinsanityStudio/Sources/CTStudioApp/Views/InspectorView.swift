import SwiftUI
import CTModels

/// The center panel: dispatches to a payload-specific inspector, or a plain
/// hex/metadata view for records this package hasn't modeled yet.
struct InspectorView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let node: ChunkNode?
    @State private var showComposite = false
    /// Cached, not recomputed in `body`: `resolveComposite` mints a fresh
    /// `ResolvedModelAsset` (fresh `UUID`, by design — see that type's own
    /// doc comment) on every call, and `body` re-evaluates on *any*
    /// `@Published` change anywhere in `workspace` (this view holds it as
    /// an `@EnvironmentObject`) — not just when `node` changes. Computing
    /// this inline in `compositeContent` used to hand `CompositePreviewView`
    /// a new asset identity on every unrelated workspace update, which
    /// tore down and rebuilt its GPU renderer in a loop for as long as the
    /// composite toggle was on — expensive on its own, and (observed
    /// directly, via the diagnostic logging added for the blank-viewport
    /// investigation) severe enough to visibly interfere with a
    /// `ModelViewerWindow` sheet open at the same time.
    @State private var resolvedComposite: ResolvedModelAsset?

    var body: some View {
        Group {
            if let node {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(for: node)
                        if Self.isCompositeEligible(node.payload) {
                            Toggle(isOn: $showComposite) {
                                Label("View Parent / Composite", systemImage: "arrow.triangle.branch")
                            }
                            .toggleStyle(.switch)
                            RelationalChainView(node: node)
                        }
                        Divider()
                        if showComposite, Self.isCompositeEligible(node.payload) {
                            compositeContent
                        } else {
                            switch node.payload {
                            case .texture(let texture):
                                TextureInspectorView(node: node, texture: texture)
                            case .mesh(let mesh):
                                MeshInspectorView(node: node, mesh: mesh)
                            case .rigidModel(let info):
                                RigidModelInspectorView(node: node, info: info)
                            case .material(let material):
                                MaterialInspectorView(material: material)
                            case .skeleton(let skeleton):
                                SkeletonInspectorView(node: node, skeleton: skeleton)
                            case .animation(let animation):
                                AnimationInspectorView(animation: animation)
                            case .position(let position):
                                PositionInspectorView(node: node, position: position)
                            case .instance(let instance):
                                InstanceInspectorView(node: node, instance: instance)
                            case .trigger(let trigger):
                                TriggerInspectorView(node: node, trigger: trigger)
                            case .camera(let camera):
                                CameraInspectorView(node: node, camera: camera)
                            case .collision(let mesh):
                                CollisionInspectorView(mesh: mesh)
                            case .scenery(let scenery):
                                SceneryInspectorView(node: node, scenery: scenery)
                            case .dynamicScenery(let dynamicScenery):
                                DynamicSceneryInspectorView(scenery: dynamicScenery)
                            case .soundEffect(let sound):
                                SoundEffectInspectorView(node: node, sound: sound)
                            case .gameObject(let gameObject):
                                GameObjectInspectorView(gameObject: gameObject)
                            case .chunkLinks(let chunkLinks):
                                ChunkLinksInspectorView(node: node, chunkLinks: chunkLinks)
                            case .raw, .none:
                                RawInspectorView(node: node)
                            }
                        }
                    }
                    .padding(20)
                }
                .onChange(of: node.id) { _, _ in
                    showComposite = false
                    updateResolvedComposite(for: node)
                }
                .onAppear { updateResolvedComposite(for: node) }
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "sidebar.left",
                    description: Text("Select a chunk, texture, model, or animation from the sidebar.")
                )
            }
        }
    }

    /// Cheap payload-kind check for whether the toggle should even appear —
    /// deliberately *not* calling `resolveComposite` here, since that walks
    /// and rebuilds the whole file's Graphics/Code index and this runs on
    /// every render of every selected node, composite-eligible or not.
    private static func isCompositeEligible(_ payload: ChunkPayload?) -> Bool {
        switch payload {
        case .texture, .mesh, .material, .animation, .rigidModel, .skeleton: return true
        case .position, .instance, .trigger, .camera, .collision, .scenery, .dynamicScenery, .soundEffect, .gameObject, .chunkLinks, .raw, .none: return false
        }
    }

    /// Only actually calls the expensive `resolveComposite` (rebuilds the
    /// whole file's Graphics/Code index) for payload kinds the composite
    /// toggle can even apply to — same guard `isCompositeEligible` already
    /// uses for whether to show the toggle at all, now also covering
    /// whether to eagerly resolve it.
    private func updateResolvedComposite(for node: ChunkNode) {
        resolvedComposite = Self.isCompositeEligible(node.payload) ? workspace.resolveComposite(for: node) : nil
    }

    @ViewBuilder
    private var compositeContent: some View {
        if let resolvedComposite {
            CompositePreviewView(asset: resolvedComposite)
        } else {
            ContentUnavailableView(
                "No Parent Found",
                systemImage: "questionmark.circle",
                description: Text("Nothing in this file currently references this record — it may be orphaned. Check the Scrapped Content Scanner.")
            )
        }
    }

    private func header(for node: ChunkNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(node.displayName)
                .font(.title2.bold())
            HStack(spacing: 12) {
                Label(node.sectionType.rawValue, systemImage: "tag")
                Label("\(node.byteSize) bytes", systemImage: "shippingbox")
                Label("offset 0x\(String(node.fileOffset, radix: 16))", systemImage: "number")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct RigidModelInspectorView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let node: ChunkNode
    let info: RigidModelInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                LabeledContent("Header", value: "0x\(String(info.header, radix: 16))")
                LabeledContent("Mesh ID", value: "\(info.meshID)")
                LabeledContent("Material Count", value: "\(info.materialIDs.count)")
                if !info.materialIDs.isEmpty {
                    DisclosureGroup("Material IDs") {
                        ForEach(info.materialIDs, id: \.self) { id in
                            Text("#\(id)").font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Button {
                workspace.openModelViewer(for: node)
            } label: {
                Label("Open in Model Viewer", systemImage: "cube.fill")
            }
        }
    }
}

struct MaterialInspectorView: View {
    let material: MaterialInfo

    var body: some View {
        Form {
            LabeledContent("Name", value: material.name)
            LabeledContent("Shader Count", value: "\(material.shaders.count)")
            if !material.shaders.isEmpty {
                DisclosureGroup("Shaders") {
                    ForEach(Array(material.shaders.enumerated()), id: \.offset) { _, shader in
                        LabeledContent("Type \(shader.shaderType)", value: "texture #\(shader.textureId)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// "Comprehensive Instance Population" (Part 4B): a read-only view of the
/// `GameObject` record an `Instance.objectID` resolves through on its way
/// to real geometry — see `GameObjectInfo`'s own doc comment for why only
/// the `OGIs` list is decoded (name + OGI links only, not the script
/// bytecode tail this codebase doesn't decode anywhere else either).
struct GameObjectInspectorView: View {
    let gameObject: GameObjectInfo

    var body: some View {
        Form {
            LabeledContent("Name", value: gameObject.name)
            LabeledContent("Object ID", value: "\(gameObject.id)")
            if !gameObject.ogiIDs.isEmpty {
                DisclosureGroup("Graphics Info Links (\(gameObject.ogiIDs.count))") {
                    ForEach(Array(gameObject.ogiIDs.enumerated()), id: \.offset) { index, ogiID in
                        LabeledContent("[\(index)]", value: ogiID == 65535 ? "none" : "#\(ogiID)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct RawInspectorView: View {
    let node: ChunkNode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if node.children.isEmpty {
                Label("Not decoded by this build — browsable as raw bytes only.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(node.children.count) child record(s). Select one to inspect it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
