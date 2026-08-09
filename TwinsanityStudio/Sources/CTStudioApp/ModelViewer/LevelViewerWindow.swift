import SwiftUI
import AppKit
import CTModels
import CTParsers
import UniformTypeIdentifiers
import AVFoundation

/// Bundles a decoded `SceneryData` record with its already-resolved
/// placements (mesh + textures per object) — resolved once, when the user
/// clicks "Open Level Viewer" (`SceneryInspectorView`), rather than redone
/// on every render of this window.
public struct LevelViewerContext: Identifiable {
    public let id = UUID()
    public var scenery: SceneryAsset
    public var placements: [(worldPosition: SIMD3<Float>, asset: ResolvedModelAsset)]
    /// "Direct .RM2 Write-Back": every `Instance` record (crate, enemy,
    /// platform, …) from the same file, paired with the `ChunkNode` its
    /// transform gets patched back into on save. Drawn as placeholder
    /// marker geometry, not a real mesh — this build has no verified
    /// mapping from an `Instance`'s `objectID` to the `RigidModel` it
    /// actually looks like (unlike `SceneryData` placements, which
    /// reference a model ID directly), so rendering anything more specific
    /// here would be a guess dressed up as data. The marker's *position* is
    /// exactly what's on disk, and dragging/saving it is fully real.
    public var instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)]
    /// "Comprehensive Instance Population" (Part 4B): real resolved
    /// geometry for whichever `instanceMarkers` entries this build could
    /// actually resolve (`WorkspaceViewModel.resolvedInstanceAssets`),
    /// keyed by that entry's `node.id`. An entry with no matching key here
    /// draws as the amber placeholder marker instead — the mandate's own
    /// "use a colored bounding-box proxy when a model is missing."
    public var resolvedInstanceAssets: [UUID: ResolvedModelAsset]
    /// "The Forge Palette" (Part 4C): the same index `resolvedInstanceAssets`
    /// was built from, kept around so `LevelViewerRenderer` can resolve a
    /// *newly placed* object's real geometry without needing a second,
    /// separate index-build pass.
    public var assetIndex: GraphicsAssetIndex
    /// "No More Placeholder Squares": the shared `Startup/Default.rm2`
    /// index — see `AssetResolver.resolveInstanceObject`'s doc comment —
    /// so a newly Forge-Palette-placed shared object also resolves to
    /// real geometry, not just existing Instance markers.
    public var defaultAssetIndex: GraphicsAssetIndex
    /// "Level Editor Overhaul": every `Trigger`/`Camera`/`SoundEffect`
    /// record from the same file — triggers/cameras feed their scene
    /// layers (wireframe boxes, select-and-inspect only, no write path
    /// yet), sounds feed the Level Audio panel.
    public var triggers: [(node: ChunkNode, trigger: TriggerVolume)]
    public var cameras: [(node: ChunkNode, camera: PlacedCamera)]
    public var sounds: [(node: ChunkNode, sound: SoundEffectAsset)]
    /// "Chunk-Based Architecture" (Part 2): every real `ChunkLink` in this
    /// chunk — each one names a neighboring `.SM2` file this level can
    /// stream in, plus (when present) the boundary wall geometry that
    /// triggers it. See `ChunkLinksAsset`'s doc comment.
    public var chunkLinks: [(node: ChunkNode, link: ChunkLink)]
    /// "AI Pathfinding/Navmesh Editor" (roadmap 5.1): real `AIPosition`
    /// waypoints (spatial, feed the "AI Waypoints" scene layer) and
    /// `AIPath` records (no position of their own — see `AIPathRecord`'s
    /// doc comment — factual list panel only).
    public var aiPositions: [(node: ChunkNode, marker: AIPositionMarker)]
    public var aiPaths: [(node: ChunkNode, path: AIPathRecord)]

    public init(
        scenery: SceneryAsset,
        placements: [(worldPosition: SIMD3<Float>, asset: ResolvedModelAsset)],
        instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)] = [],
        resolvedInstanceAssets: [UUID: ResolvedModelAsset] = [:],
        assetIndex: GraphicsAssetIndex = GraphicsAssetIndex(),
        defaultAssetIndex: GraphicsAssetIndex = GraphicsAssetIndex(),
        triggers: [(node: ChunkNode, trigger: TriggerVolume)] = [],
        cameras: [(node: ChunkNode, camera: PlacedCamera)] = [],
        sounds: [(node: ChunkNode, sound: SoundEffectAsset)] = [],
        chunkLinks: [(node: ChunkNode, link: ChunkLink)] = [],
        aiPositions: [(node: ChunkNode, marker: AIPositionMarker)] = [],
        aiPaths: [(node: ChunkNode, path: AIPathRecord)] = []
    ) {
        self.scenery = scenery
        self.placements = placements
        self.instanceMarkers = instanceMarkers
        self.resolvedInstanceAssets = resolvedInstanceAssets
        self.assetIndex = assetIndex
        self.defaultAssetIndex = defaultAssetIndex
        self.triggers = triggers
        self.cameras = cameras
        self.sounds = sounds
        self.chunkLinks = chunkLinks
        self.aiPositions = aiPositions
        self.aiPaths = aiPaths
    }
}

/// "Scenery/Level Assembly" + "Forge-Style Editor Mode" (blueprint 6.1/6.2):
/// a multi-object Metal viewport drawing every resolved scenery placement,
/// with a translate gizmo on the selected object, coordinate nudge fields,
/// snap-to-grid, and a drag target for adding new objects from the Models
/// Hub. Scenery placements themselves still have no write path — see
/// `LevelViewerContext.instanceMarkers`'s doc comment — but the amber
/// marker cubes alongside them (one per `Instance` record: crate, enemy,
/// platform, …) are fully save-able via "Save Level Overrides…", the same
/// safe decode -> edit -> encode -> patch -> save-as-copy loop used
/// throughout this build.
/// "Level Editor Overhaul": a coarse preset over the "Scene Layers" panel
/// below — picking one just sets `layerVisibility` to a sensible starting
/// combination; the checkboxes remain independently adjustable afterward,
/// same as the request's "regardless of mode" wording.
enum LevelViewMode: CaseIterable {
    case geometryOnly, populated

    var displayName: String {
        switch self {
        case .geometryOnly: return "Geometry Only"
        case .populated: return "Fully Populated"
        }
    }

    var layerPreset: Set<SceneLayer> {
        switch self {
        case .geometryOnly: return [.scenery]
        case .populated: return Set(SceneLayer.allCases)
        }
    }
}

struct LevelViewerWindow: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.undoManager) private var undoManager
    let context: LevelViewerContext

    @State private var renderer: LevelViewerRenderer?
    @State private var selectedIndex: Int?
    @State private var viewMode: LevelViewMode = .populated
    @State private var layerVisibility: Set<SceneLayer> = Set(SceneLayer.allCases)
    @State private var positionX: String = ""
    @State private var positionY: String = ""
    @State private var positionZ: String = ""
    @State private var rotationX: String = ""
    @State private var rotationY: String = ""
    @State private var rotationZ: String = ""
    @State private var scaleX: String = ""
    @State private var scaleY: String = ""
    @State private var scaleZ: String = ""
    @State private var gizmoMode: GizmoMode = .translate
    @State private var snapToGrid = true
    @State private var gridSize: Double = 1.0
    @State private var rotationSnapDegrees: Double = 15.0
    @State private var isDropTargeted = false
    /// "The Forge Palette" (Part 4C): non-nil while a palette pick is armed
    /// and waiting for the viewport click that places it — mirrors
    /// `renderer.pendingPlacementObjectID` into SwiftUI `@State` the same
    /// way `selectedIndex` mirrors `renderer.selectedObjectIndex`, since
    /// the renderer itself is a plain class AppKit mutates directly, not an
    /// `ObservableObject`.
    @State private var armedPlacement: (objectID: UInt16, name: String)?
    /// "Scene Preview Mode" (roadmap 7.1) — see `scenePreviewModeToggle`'s
    /// doc comment.
    @State private var isScenePreviewMode = false
    /// "Free Camera System in Chunk Editor".
    @State private var isFreeCameraMode = false
    @State private var scenePreviewTimer: Timer?
    /// "Recipe Book" (roadmap 6.4).
    @State private var isRecipeBookPresented = false
    /// "Chunk-Based Architecture" (Part 2): which `ChunkLink.id`s have
    /// already been loaded into the viewport this session (so the button
    /// can show "Loaded" instead of offering to reload the same neighbor),
    /// and which one is actively resolving right now (for a small progress
    /// indicator on that one row only).
    @State private var stitchedLinkIDs: Set<Int> = []
    @State private var stitchingLinkID: Int?
    /// "Cross-Engine Chunk Stitcher" (roadmap 5.3): a running log of what's
    /// been loaded this session — file name plus real decoded counts, or
    /// an error, so the user can see what actually got stitched in.
    @State private var crossEngineLoadLog: [String] = []
    /// Full transform captured at the start of a gizmo drag or a
    /// nudge-field edit, so ⌘Z has something to restore to — see
    /// `registerUndo`. Snapshotting all three (not just whichever one a
    /// given drag actually changes) keeps one undo mechanism instead of
    /// three near-identical ones.
    @State private var transformBeforeEdit: TransformSnapshot?

    private struct TransformSnapshot: Equatable {
        var position: SIMD3<Float>
        var rotationDegrees: SIMD3<Float>
        var scale: SIMD3<Float>
    }

    var body: some View {
        HStack(spacing: 0) {
            viewportArea
            Divider()
            sidebar
                .frame(width: 320)
        }
        .frame(minWidth: 960, minHeight: 620)
        .onAppear {
            renderer = LevelViewerRenderer(
                placements: context.placements,
                instanceMarkers: context.instanceMarkers,
                resolvedInstanceAssets: context.resolvedInstanceAssets,
                assetIndex: context.assetIndex,
                defaultAssetIndex: context.defaultAssetIndex,
                triggers: context.triggers,
                cameras: context.cameras,
                chunkLinks: context.chunkLinks,
                aiPositions: context.aiPositions
            )
            renderer?.snapToGrid = snapToGrid
            renderer?.gridSize = Float(gridSize)
            renderer?.rotationSnapDegrees = Float(rotationSnapDegrees)
            renderer?.layerVisibility = layerVisibility
        }
        // "Robust Undo/Redo" (QoL sweep), scoped to object moves — the one
        // piece of mutable state this session actually introduced and
        // fully understands the surface of. `NSUndoManager` doesn't route
        // its undo/redo effects back into SwiftUI `@State` on its own, so
        // these notifications (which it posts specifically for observers
        // to resync after an undo/redo) are what keep the sidebar's
        // selection/position fields in sync after ⌘Z/⌘⇧Z.
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in syncFromRenderer() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in syncFromRenderer() }
        .onDisappear { stopScenePreviewTimer() }
    }

    private func syncFromRenderer() {
        selectedIndex = renderer?.selectedObjectIndex
        refreshTransformFields()
    }

    @ViewBuilder
    private var viewportArea: some View {
        if let renderer {
            if renderer.hasGeometry {
                // See `ModelViewerWindow`'s matching comment — an
                // `NSViewRepresentable` `MTKView` has no intrinsic size, so
                // this needs an explicit expand-to-fill or it can collapse
                // inside the surrounding `HStack`.
                ZStack(alignment: .bottomLeading) {
                    MetalModelView(
                        renderer: renderer,
                        onGizmoDragEnded: {
                            registerUndo(from: transformBeforeEdit)
                            refreshTransformFields()
                        },
                        onGizmoDragStarted: { transformBeforeEdit = currentSnapshot() },
                        onGizmoModeChanged: { gizmoMode = renderer.gizmoMode },
                        onObjectPicked: { index in select(index) },
                        onObjectPlaced: { index in
                            selectedIndex = index
                            refreshTransformFields()
                            registerPlacementUndo(index: index)
                            armedPlacement = nil
                        }
                    )
                    // See `ModelViewerWindow`'s matching comment — a
                    // `maxWidth/maxHeight: .infinity`-only frame isn't a
                    // concrete enough size for a `.sheet()`'s first layout
                    // pass to reliably drive the `MTKView` from.
                    .frame(minWidth: 400, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                    if let armedPlacement {
                        HStack(spacing: 8) {
                            Image(systemName: "hammer.fill")
                            Text("Click in the viewport to place **\(armedPlacement.name)**")
                            Button("Cancel") {
                                self.armedPlacement = nil
                                renderer.pendingPlacementObjectID = nil
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.caption)
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                    } else {
                        Text("Drag to orbit · Scroll to zoom · Drag a handle to \(gizmoMode == .translate ? "move" : gizmoMode == .rotate ? "rotate" : "scale") the selection · W/E/R to switch · F to frame")
                            .font(.caption)
                            .padding(6)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(10)
                    }
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dropDestination(for: String.self) { items, _ in
                    guard let idString = items.first,
                          let asset = workspace.modelsHub.first(where: { $0.id.uuidString == idString })
                    else { return false }
                    guard let newIndex = renderer.addObject(asset: asset) else { return false }
                    selectedIndex = newIndex
                    refreshTransformFields()
                    return true
                } isTargeted: { isDropTargeted = $0 }
            } else {
                ContentUnavailableView(
                    "No Resolvable Placements",
                    systemImage: "map",
                    description: Text("This level's scenery tree decoded (\(context.scenery.placements.count) placement(s) total), but none of their model IDs matched a RigidModel in this file's Graphics section.")
                )
            }
        } else {
            ContentUnavailableView("Metal Unavailable", systemImage: "exclamationmark.triangle", description: Text("Couldn't initialize a Metal device on this Mac."))
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(context.scenery.chunkName.isEmpty ? "Chunk" : context.scenery.chunkName)
                    .font(.title3.bold())

                modeAndLayersPanel

                Divider()

                ForgePaletteView { objectID, name in
                    armedPlacement = (objectID, name)
                    renderer?.pendingPlacementObjectID = objectID
                }

                Form {
                    LabeledContent("Placements in tree", value: "\(context.scenery.placements.count)")
                    LabeledContent("Scenery resolved", value: "\(context.placements.count)")
                    LabeledContent("Instance markers", value: "\(context.instanceMarkers.count)")
                    LabeledContent("Triggers", value: "\(context.triggers.count)")
                    LabeledContent("Cameras", value: "\(context.cameras.count)")
                }
                .formStyle(.grouped)

                Text("Scenery objects are drawn at their correct world position, but not yet rotated or scaled to match the chunk data — only translation is currently applied, and scenery has no write path yet (in-session sandbox only). The amber cubes are Instance records (crate/enemy/platform placements) — their position/rotation is real, live-editable with the gizmo, and \"Save Chunk Overrides…\" below writes it back to a copy of the file. Green/cyan wireframe boxes are Triggers/Cameras — click to select and inspect; no 3D gizmo yet, but their inspector panel below has real, writable position/size/rotation fields with their own \"Save Edited Copy…\" button. The small magenta boxes along a camera's path are its real spline/path control points — click and drag one with the gizmo like any other object; \"Save Chunk Overrides…\" patches each moved point's own 16 bytes straight into the file, without needing to re-encode the rest of that Camera record. Inserting or removing a control point isn't supported yet — only moving an existing one.")
                    .font(.caption2)
                    .foregroundStyle(.orange)

                if let referenceNode = referenceNodeForFileOps {
                    Button("Save Chunk Overrides…") { saveLevelOverrides() }
                        .disabled(!workspace.canSaveEdits(for: referenceNode))
                    if !workspace.canSaveEdits(for: referenceNode) {
                        Text("Editing only saves for a standalone-opened .RM2/.SM2 file — this level's file is archive-packed, which this build doesn't have a write path for yet.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                gizmoControls

                if let node = renderer?.selectedSourceNode {
                    Divider()
                    selectedObjectInspector(node: node)
                }

                Divider()

                objectList

                if !context.sounds.isEmpty {
                    Divider()
                    LevelAudioPanel(sounds: context.sounds)
                }

                if !context.triggers.isEmpty || hasScriptedInstances {
                    Divider()
                    levelEventsPanel
                }

                if !context.chunkLinks.isEmpty {
                    Divider()
                    chunkLinksPanel
                }

                if !context.aiPositions.isEmpty || !context.aiPaths.isEmpty {
                    Divider()
                    aiWaypointsPanel
                }

                if !context.aiPaths.isEmpty {
                    Divider()
                    aiPathsPanel
                }

                Divider()
                crossEngineDataPanel
            }
            .padding(16)
        }
    }

    /// "Viewport Rendering Modes" + "Granular Layer Visibility": the mode
    /// picker is a preset over the same `layerVisibility` the checkboxes
    /// edit directly — see `LevelViewMode.layerPreset`'s doc comment.
    private var modeAndLayersPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: $viewMode) {
                ForEach(LevelViewMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: viewMode) { _, newValue in
                layerVisibility = newValue.layerPreset
                renderer?.layerVisibility = layerVisibility
            }

            Text("Scene Layers").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(SceneLayer.allCases, id: \.self) { layer in
                Toggle(layer.displayName, isOn: layerBinding(for: layer))
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            Divider()
            freeCameraToggle

            Divider()
            scenePreviewModeToggle

            Divider()
            Button {
                isRecipeBookPresented = true
            } label: {
                Label("Recipe Book…", systemImage: "wand.and.stars")
            }
            .disabled(context.instanceMarkers.isEmpty)
            .help("Reassign which real object each placement in this chunk resolves to.")
        }
        .sheet(isPresented: $isRecipeBookPresented) {
            if let referenceNode = referenceNodeForFileOps {
                RecipeBookView(
                    instanceMarkers: context.instanceMarkers,
                    resolvedInstanceAssets: context.resolvedInstanceAssets,
                    referenceNode: referenceNode
                )
                .environmentObject(workspace)
            }
        }
    }

    /// "Active Chunk & Asset Preview Engine" (roadmap 7.1) — a real,
    /// honest slice of "Scene Preview Mode": while orbiting/zooming, the
    /// camera's real world position is tested against every real decoded
    /// Trigger volume (`LevelViewerRenderer.triggerContains`), and any
    /// trigger the camera is currently "inside" highlights bright red.
    /// Deliberately not a game runtime — no player character, no physics,
    /// no live BGM/animation-cycling system; this build has no decoded
    /// trigger *semantics* to react to (see `SceneLayer.triggers`'s own
    /// history in this codebase for why "what a trigger does" isn't
    /// claimed anywhere else either), just real geometry a real camera
    /// position can be tested against.
    /// "Free Camera System in Chunk Editor": a real, independent 6-DOF
    /// flying camera — WASD/EQ to move, right-click-drag to look, scroll
    /// wheel to adjust speed, no collision (this build has no physics
    /// body to collide with anyway). Off by default; toggling it starts
    /// exactly where the orbit camera currently is/looks, so switching
    /// modes mid-session never jump-cuts the view.
    private var freeCameraToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Free Camera", isOn: $isFreeCameraMode)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: isFreeCameraMode) { _, isOn in
                    renderer?.isFreeCameraMode = isOn
                }
            Text(isFreeCameraMode
                ? "WASD to move, E/Q for up/down, right-click-drag to look, scroll to adjust speed."
                : "Fly freely instead of orbiting a fixed point.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var scenePreviewModeToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Scene Preview Mode", isOn: $isScenePreviewMode)
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(context.triggers.isEmpty)
                .onChange(of: isScenePreviewMode) { _, isOn in
                    if isOn { startScenePreviewTimer() } else { stopScenePreviewTimer() }
                }
            if isScenePreviewMode {
                Text(activeTriggerStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Highlights any real Trigger volume the camera is currently inside while orbiting — the camera itself, not a player character (this build has no physics/player controller).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activeTriggerStatusText: String {
        let activeIDs = renderer?.activeTriggerIDs ?? []
        guard !activeIDs.isEmpty else { return "Camera is outside every trigger volume." }
        return "Camera is inside: " + activeIDs.sorted().map { "#\($0)" }.joined(separator: ", ")
    }

    private func startScenePreviewTimer() {
        scenePreviewTimer?.invalidate()
        scenePreviewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) { _ in
            renderer?.updateActiveTriggers()
        }
    }

    private func stopScenePreviewTimer() {
        scenePreviewTimer?.invalidate()
        scenePreviewTimer = nil
        renderer?.activeTriggerIDs = []
    }

    private func layerBinding(for layer: SceneLayer) -> Binding<Bool> {
        Binding(
            get: { layerVisibility.contains(layer) },
            set: { isOn in
                if isOn { layerVisibility.insert(layer) } else { layerVisibility.remove(layer) }
                renderer?.layerVisibility = layerVisibility
            }
        )
    }

    /// "Click any rendered element to select it… open its property
    /// inspector": routes on `node.payload` to the same real inspector
    /// views the sidebar tree already uses — no separate/duplicated
    /// inspector logic for the Level Viewer.
    @ViewBuilder
    private func selectedObjectInspector(node: ChunkNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected Object").font(.headline)
            switch node.payload {
            case .instance(let instance):
                InstanceInspectorView(node: node, instance: instance)
            case .trigger(let trigger):
                TriggerInspectorView(node: node, trigger: trigger)
            case .camera(let camera):
                CameraInspectorView(node: node, camera: camera)
            case .aiPosition(let marker):
                AIPositionInspectorView(marker: marker)
            default:
                Text("No inspector available for this record type.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hasScriptedInstances: Bool {
        context.instanceMarkers.contains { $0.instance.scriptID != -1 }
    }

    /// "Level Scripts / Cutscenes": real decoded data (trigger
    /// args/flags, instance script IDs), factually presented — not the
    /// "plain English event descriptions" this build has no source for
    /// (no script bytecode decoder exists here to describe *what* a
    /// trigger/scriptID actually does). Titled "Level Events" rather than
    /// "Scripts" for exactly that reason. Clicking a row selects the
    /// underlying object, which (via `orbitTarget` already following the
    /// current selection) snaps the camera to it.
    private var levelEventsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chunk Events").font(.headline)
            Text("Factual listing of Trigger volumes and script-carrying Instances — this build doesn't decode script bytecode, so there's no plain-English description of what any of these actually do.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(context.triggers, id: \.node.id) { entry in
                eventRow(
                    icon: "square.dashed",
                    title: "Trigger #\(entry.trigger.id)",
                    subtitle: "args \(entry.trigger.arg1)/\(entry.trigger.arg2)/\(entry.trigger.arg3)/\(entry.trigger.arg4) · mask 0b\(String(entry.trigger.enabledMask, radix: 2))",
                    node: entry.node
                )
            }
            ForEach(context.instanceMarkers.filter { $0.instance.scriptID != -1 }, id: \.node.id) { entry in
                eventRow(
                    icon: "cube.transparent.fill",
                    title: "Instance #\(entry.instance.id)",
                    subtitle: "scriptID \(entry.instance.scriptID) · objectID \(entry.instance.objectID)",
                    node: entry.node
                )
            }
        }
    }

    private func eventRow(icon: String, title: String, subtitle: String, node: ChunkNode) -> some View {
        Button {
            renderer?.selectByNode(node)
            selectedIndex = renderer?.selectedObjectIndex
            refreshTransformFields()
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(4)
        }
        .buttonStyle(.plain)
    }

    /// "Chunk-Based Architecture" (Part 2): the real, decoded list of
    /// neighboring chunk files this level can stream in (`ChunkLinks`),
    /// with a "Load & Stitch" action per link that resolves the neighbor
    /// against whatever archives are currently open and appends its
    /// scenery into this same viewport (`LevelViewerRenderer.stitchChunk`).
    private var chunkLinksPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chunk Links").font(.headline)
            Text("Real neighboring-chunk references decoded from this level's own file. \"Load & Stitch\" only works if that neighbor's archive is already open in this workspace.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(context.chunkLinks, id: \.link.id) { entry in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.link.path).font(.caption).lineLimit(1)
                        Text(entry.link.hasWall ? "Boundary wall present" : "No boundary wall")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if stitchingLinkID == entry.link.id {
                        ProgressView().controlSize(.small)
                    } else if stitchedLinkIDs.contains(entry.link.id) {
                        Label("Loaded", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Button("Load & Stitch") { loadAndStitch(entry.link) }
                            .font(.caption2)
                    }
                }
                .padding(4)
            }
        }
    }

    private func loadAndStitch(_ link: ChunkLink) {
        stitchingLinkID = link.id
        Task {
            defer { stitchingLinkID = nil }
            guard let result = await workspace.loadChunkLinkPlacements(for: link) else {
                workspace.lastError = "Couldn't find \"\(link.path)\" in any currently open archive — open the level or archive it belongs to first."
                return
            }
            guard !result.placements.isEmpty else {
                workspace.lastError = "\(result.fileName) resolved but has no scenery placements to show."
                return
            }
            let offset = link.chunkMatrix.count > 3
                ? SIMD3(link.chunkMatrix[3].x, link.chunkMatrix[3].y, link.chunkMatrix[3].z)
                : SIMD3<Float>.zero
            let added = renderer?.stitchChunk(placements: result.placements, worldOffset: offset) ?? 0
            stitchedLinkIDs.insert(link.id)
            layerVisibility.insert(.linkedChunks)
            renderer?.layerVisibility = layerVisibility
            workspace.statusMessage = "Stitched \(added) object(s) from \(result.fileName)."
        }
    }

    /// "Cross-Engine Chunk Stitcher" (roadmap 5.3): the mandate's other
    /// half of "load chunk files from different engines... side-by-side."
    /// A real Wrath of Cortex `.CRT`/`.WMP` file, parsed by
    /// `WrathOfCortexParser` (ported from CrateModLoader's real, working
    /// decoder — see `WOCCrateFile`'s doc comment for the "not verified
    /// against real WoC bytes" caveat, since no WoC disc image is
    /// available in this environment), plotted directly into this same
    /// Twinsanity chunk's viewport as a separate, offset, independently
    /// toggleable layer.
    private var crossEngineDataPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cross-Engine Data").font(.headline)
            Text("Load a real Wrath of Cortex .CRT (crates) or .WMP (Wumpa fruit) file and plot it alongside this chunk, offset 20 units on X so it doesn't overlap.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Load Wrath of Cortex File…") { loadCrossEngineFile() }
            ForEach(Array(crossEngineLoadLog.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadCrossEngineFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a real Wrath of Cortex .CRT (crates) or .WMP (Wumpa fruit) file."
        panel.prompt = "Load"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Fixed offset so the cross-engine data doesn't land on top of the
        // currently loaded chunk — these two games have no real shared
        // coordinate space to align through, unlike `ChunkLink.chunkMatrix`
        // (a real, decoded alignment transform for same-engine neighbors).
        let offset = SIMD3<Float>(20, 0, 0)
        do {
            let data = try Data(contentsOf: url)
            switch url.pathExtension.lowercased() {
            case "crt":
                let file = try WrathOfCortexParser.parseCrateFile(data)
                let positions = file.groups.flatMap { $0.crates.map(\.position) }
                renderer?.stitchCrossEngineData(crates: positions, wumpas: [], worldOffset: offset)
                layerVisibility.insert(.crossEngine)
                renderer?.layerVisibility = layerVisibility
                crossEngineLoadLog.append("\(url.lastPathComponent): \(file.groups.count) group(s), \(file.totalCrateCount) crate(s)")
            case "wmp":
                let file = try WrathOfCortexParser.parseWumpaFile(data)
                renderer?.stitchCrossEngineData(crates: [], wumpas: file.positions, worldOffset: offset)
                layerVisibility.insert(.crossEngine)
                renderer?.layerVisibility = layerVisibility
                crossEngineLoadLog.append("\(url.lastPathComponent): \(file.positions.count) Wumpa position(s)")
            default:
                workspace.lastError = "Unrecognized file — expected a .CRT or .WMP Wrath of Cortex file."
            }
        } catch {
            workspace.lastError = "Failed to parse \(url.lastPathComponent): \(error)"
        }
    }

    @ViewBuilder
    private var gizmoControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transform").font(.headline)

            Picker("Gizmo", selection: $gizmoMode) {
                Text("Move (W)").tag(GizmoMode.translate)
                Text("Rotate (E)").tag(GizmoMode.rotate)
                Text("Scale (R)").tag(GizmoMode.scale)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: gizmoMode) { _, newValue in renderer?.gizmoMode = newValue }

            Toggle("Snap to Grid", isOn: $snapToGrid)
                .toggleStyle(.checkbox)
                .help("When on, dragging a gizmo handle rounds the edited value to the nearest snap step instead of moving freely.")
                .onChange(of: snapToGrid) { _, newValue in renderer?.snapToGrid = newValue }

            HStack {
                Text("Grid Size")
                Stepper(value: $gridSize, in: 0.1...100, step: 0.5) {
                    Text(String(format: "%.1f", gridSize))
                }
                .help("World units between move/scale snap points.")
                .onChange(of: gridSize) { _, newValue in renderer?.gridSize = Float(newValue) }
            }
            HStack {
                Text("Rotation Snap")
                Stepper(value: $rotationSnapDegrees, in: 1...90, step: 5) {
                    Text("\(Int(rotationSnapDegrees))°")
                }
                .help("Degrees between rotation snap points.")
                .onChange(of: rotationSnapDegrees) { _, newValue in renderer?.rotationSnapDegrees = Float(newValue) }
            }

            if selectedIndex != nil {
                transformFieldGroup(title: "Position", x: $positionX, y: $positionY, z: $positionZ, apply: applyPositionFields)
                transformFieldGroup(title: "Rotation °", x: $rotationX, y: $rotationY, z: $rotationZ, apply: applyRotationFields)
                transformFieldGroup(title: "Scale", x: $scaleX, y: $scaleY, z: $scaleZ, apply: applyScaleFields)
                Button {
                    duplicateSelected()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!canDuplicateSelected)
                .help(canDuplicateSelected
                    ? "Duplicate the selected object, with real write-back to disk on save."
                    : "Only Actor/Instance placements and AI waypoints can be duplicated — scenery, triggers, and cameras have no write path back to the file yet.")
            } else {
                Text("Select an object below (or drag one from the Models Hub into the viewport) to transform it with the gizmo or these fields.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func transformFieldGroup(title: String, x: Binding<String>, y: Binding<String>, z: Binding<String>, apply: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow { Text("X"); transformField(x, apply: apply) }
                GridRow { Text("Y"); transformField(y, apply: apply) }
                GridRow { Text("Z"); transformField(z, apply: apply) }
            }
            Button("Apply") { apply() }
                .help("⌘Z undoes it, same as a gizmo drag.")
        }
    }

    private func transformField(_ text: Binding<String>, apply: @escaping () -> Void) -> some View {
        TextField("", text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
            .onSubmit(apply)
    }

    /// "AI Pathfinding/Navmesh Editor" (roadmap 5.1): real write-back for
    /// waypoints — "Add Waypoint" inserts a brand-new, real `AIPosition`
    /// record (`ChunkSectionInserter`, the same generic insertion path the
    /// Forge Palette already trusts for Instance records) and every
    /// waypoint's current position (dragged or freshly placed) saves via
    /// "Save Chunk Overrides…" below, since `AIPosition` is fixed-size —
    /// no separate "remove a waypoint" button: shrinking a section safely
    /// is real, separate work this build doesn't have yet.
    private var aiWaypointsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI Waypoints (\(context.aiPositions.count))").font(.headline)
            Text("Drag a waypoint with the gizmo like any other object — its new position saves for real via \"Save Chunk Overrides…\" below. \"Add Waypoint\" places a brand-new, real AIPosition record.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Add Waypoint") { addAIWaypoint() }
        }
    }

    private func addAIWaypoint() {
        guard let renderer, let index = renderer.spawnAIWaypoint() else { return }
        selectedIndex = index
        refreshTransformFields()
        guard let undoManager else { return }
        undoManager.setActionName("Add AI Waypoint")
        Self.registerAIWaypointPlacementUndo(undoManager: undoManager, renderer: renderer, index: index)
    }

    /// Same recursive add/remove undo shape as `registerPlacementUndo`, for
    /// `spawnAIWaypoint` instead of `spawnInstance`.
    private static func registerAIWaypointPlacementUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, index: Int) {
        guard let snapshot = renderer.newAIWaypointInfo(at: index) else { return }
        undoManager.registerUndo(withTarget: renderer) { target in
            target.removeObject(at: index)
            undoManager.registerUndo(withTarget: target) { redoTarget in
                let newIndex = redoTarget.spawnAIWaypoint(at: snapshot.worldPosition, rawNodeType: snapshot.rawNodeType) ?? index
                registerAIWaypointPlacementUndo(undoManager: undoManager, renderer: redoTarget, index: newIndex)
            }
        }
    }

    /// "AI Pathfinding/Navmesh Editor" (roadmap 5.1): the real `AIPath`
    /// records in this file — no position of their own (see
    /// `AIPathRecord`'s doc comment), so a factual list rather than a
    /// scene-layer overlay. `AIPosition` waypoints render in the viewport
    /// instead (the "AI Waypoints" scene layer).
    private var aiPathsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI Paths").font(.headline)
            Text("Real AIPath records — 5 raw arguments each, no confirmed link to any AI Waypoint (the reference tool's own editor doesn't interpret these either).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(context.aiPaths, id: \.node.id) { entry in
                Text("Path #\(entry.path.id): \(entry.path.args.map(String.init).joined(separator: ", "))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var objectList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Objects (\(renderer?.objectCount ?? 0))").font(.headline)
            ForEach(renderer?.objectSummaries ?? [], id: \.index) { summary in
                Button {
                    select(summary.index)
                } label: {
                    HStack {
                        Image(systemName: "cube.fill")
                            .foregroundStyle(selectedIndex == summary.index ? Color.accentColor : Color.secondary)
                        Text(summary.displayName)
                            .lineLimit(1)
                            .font(.caption)
                    }
                    .contentShape(Rectangle())
                    .padding(4)
                    .background(selectedIndex == summary.index ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func select(_ index: Int) {
        selectedIndex = index
        renderer?.select(index: index)
        refreshTransformFields()
    }

    private func currentSnapshot() -> TransformSnapshot? {
        guard let renderer,
              let position = renderer.selectedPosition,
              let rotationDegrees = renderer.selectedRotationDegrees,
              let scale = renderer.selectedScale
        else { return nil }
        return TransformSnapshot(position: position, rotationDegrees: rotationDegrees, scale: scale)
    }

    private func refreshTransformFields() {
        guard let snapshot = currentSnapshot() else { return }
        positionX = String(format: "%.2f", snapshot.position.x)
        positionY = String(format: "%.2f", snapshot.position.y)
        positionZ = String(format: "%.2f", snapshot.position.z)
        rotationX = String(format: "%.1f", snapshot.rotationDegrees.x)
        rotationY = String(format: "%.1f", snapshot.rotationDegrees.y)
        rotationZ = String(format: "%.1f", snapshot.rotationDegrees.z)
        scaleX = String(format: "%.2f", snapshot.scale.x)
        scaleY = String(format: "%.2f", snapshot.scale.y)
        scaleZ = String(format: "%.2f", snapshot.scale.z)
    }

    private func applyPositionFields() {
        guard let x = Float(positionX), let y = Float(positionY), let z = Float(positionZ) else { return }
        let before = currentSnapshot()
        renderer?.setSelectedPosition(to: SIMD3(x, y, z))
        registerUndo(from: before)
        refreshTransformFields()
    }

    private func applyRotationFields() {
        guard let x = Float(rotationX), let y = Float(rotationY), let z = Float(rotationZ) else { return }
        let before = currentSnapshot()
        renderer?.setSelectedRotation(eulerDegrees: SIMD3(x, y, z))
        registerUndo(from: before)
        refreshTransformFields()
    }

    private func applyScaleFields() {
        guard let x = Float(scaleX), let y = Float(scaleY), let z = Float(scaleZ) else { return }
        let before = currentSnapshot()
        renderer?.setSelectedScale(to: SIMD3(x, y, z))
        registerUndo(from: before)
        refreshTransformFields()
    }

    /// "Direct .RM2 Write-Back": collects every Instance marker's current
    /// transform (`LevelViewerRenderer.pendingLevelOverrides` — already
    /// encoded, already paired with its owning `ChunkNode`) and patches all
    /// of them into one copy of the level's file bytes, so moving several
    /// objects and saving once produces one consistent file. Scenery
    /// placements aren't included — they still have no write path (see this
    /// file's own top-level doc comment).
    /// A node this level's file-scoped operations (`canSaveEdits`,
    /// `originalFileName`) can anchor off of — any node in the same file
    /// works identically for those, since they only use it to find the
    /// enclosing file root. Prefers an Instance marker (the common case),
    /// falling back to a Trigger/Camera so "Save Level Overrides…" is
    /// still reachable for a level with new Forge Palette placements but
    /// no pre-existing Instance records of its own.
    private var referenceNodeForFileOps: ChunkNode? {
        context.instanceMarkers.first?.node ?? context.triggers.first?.node ?? context.cameras.first?.node
    }

    /// "Backend Requirement: safely inject this new record" (Part 4D) —
    /// one save now covers both existing-object transform edits
    /// (`pendingLevelOverrides`, unchanged) and brand-new Forge Palette
    /// placements (`pendingNewInstances`, encoded here via
    /// `WorldPlacementWriter.writeNewInstance` and structurally inserted
    /// by `ChunkSectionInserter`) in one combined file write.
    private func saveLevelOverrides() {
        guard let renderer, let referenceNode = referenceNodeForFileOps else { return }
        let edits = renderer.pendingLevelOverrides + renderer.pendingAIWaypointOverrides
        let controlPointEdits = renderer.pendingCameraControlPointOverrides
        let newInstances = renderer.pendingNewInstances
        let newAIPositions = renderer.pendingNewAIPositions
        guard !edits.isEmpty || !controlPointEdits.isEmpty || !newInstances.isEmpty || !newAIPositions.isEmpty else { return }

        let encodedNewInstances = newInstances.map { entry in
            (id: entry.syntheticID, encoded: WorldPlacementWriter.writeNewInstance(
                objectID: entry.objectID,
                position: SIMD4<Float>(entry.position, 1),
                rotationDegrees: entry.rotationDegrees
            ))
        }
        guard let patchedBytes = workspace.patchedFileBytes(
            applyingPrefixPatches: edits,
            applyingAbsoluteByteRangePatches: controlPointEdits,
            insertingNewInstances: encodedNewInstances,
            insertingNewAIPositions: newAIPositions,
            levelNode: referenceNode
        ) else { return }

        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(workspace.originalFileName(for: referenceNode) ?? "chunk")_edited.rm2",
            message: "Save the edited copy of this file, with every Instance/AI Waypoint/Camera control point's current position applied and every newly placed object/waypoint added. The original file on disk is not modified."
        ) else { return }
        do {
            try patchedBytes.write(to: url)
            var summary = "Saved edited copy to \(url.lastPathComponent)"
            var parts: [String] = []
            if !edits.isEmpty { parts.append("\(edits.count) transform override(s)") }
            if !controlPointEdits.isEmpty { parts.append("\(controlPointEdits.count) camera control point(s)") }
            if !newInstances.isEmpty { parts.append("\(newInstances.count) newly placed object(s)") }
            if !newAIPositions.isEmpty { parts.append("\(newAIPositions.count) newly placed waypoint(s)") }
            summary += " with " + parts.joined(separator: " and ") + ". The original file was not modified."
            workspace.statusMessage = summary
        } catch {
            workspace.lastError = "Save failed: \(error)"
        }
    }

    /// Registers one ⌘Z step restoring the selected object's full
    /// transform to `previousSnapshot`, and (via the recursive helper
    /// below) a matching ⌘⇧Z redo back to where it ended up — deliberately
    /// built entirely from stable references (`undoManager`, `renderer`,
    /// the object's index, plain value-type snapshots), not by capturing
    /// `self`/`@State` inside the closure `UndoManager` holds onto: this
    /// View struct gets recreated on every SwiftUI re-render, and a stale
    /// captured copy of it would be the wrong kind of thing for a
    /// long-lived undo stack to hold a reference to. One snapshot-based
    /// mechanism covers position/rotation/scale edits alike, rather than
    /// three near-identical ones.
    private func registerUndo(from previousSnapshot: TransformSnapshot?) {
        guard let undoManager, let previousSnapshot, let index = selectedIndex, let renderer,
              let newSnapshot = currentSnapshot(), newSnapshot != previousSnapshot
        else { return }
        undoManager.setActionName("Edit Transform")
        Self.registerTransformUndo(undoManager: undoManager, renderer: renderer, index: index, restoreTo: previousSnapshot, thenRedoTo: newSnapshot)
    }

    private static func registerTransformUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, index: Int, restoreTo: TransformSnapshot, thenRedoTo: TransformSnapshot) {
        undoManager.registerUndo(withTarget: renderer) { target in
            target.select(index: index)
            target.setSelectedPosition(to: restoreTo.position)
            target.setSelectedRotation(eulerDegrees: restoreTo.rotationDegrees)
            target.setSelectedScale(to: restoreTo.scale)
            registerTransformUndo(undoManager: undoManager, renderer: target, index: index, restoreTo: thenRedoTo, thenRedoTo: restoreTo)
        }
    }

    /// "Robust Undo/Redo… for item placement" (Part 4D): the add/remove
    /// counterpart to `registerTransformUndo`, same recursive
    /// undo-then-register-the-opposite-as-the-next-undo shape. ⌘Z removes
    /// the just-placed object; ⌘⇧Z (registered as the undo *of that*
    /// removal) re-spawns it via `spawnInstance` at the exact same
    /// position, which also re-resolves its geometry — cheap, and avoids
    /// this renderer needing to cache GPU buffers for an object that isn't
    /// currently in the scene.
    private func registerPlacementUndo(index: Int) {
        guard let undoManager, let renderer else { return }
        undoManager.setActionName("Place Object")
        Self.registerPlacementUndo(undoManager: undoManager, renderer: renderer, index: index)
    }

    private var canDuplicateSelected: Bool {
        guard let renderer, let selectedIndex else { return false }
        return renderer.canDuplicate(at: selectedIndex)
    }

    /// "Unrestricted Chunk Free-Edit Mode": duplicates the selected
    /// object via `LevelViewerRenderer.duplicateSelectedObject` (a real
    /// spawn through the same pipeline the Forge Palette uses), then
    /// registers exactly the same kind of add/remove undo step a fresh
    /// placement gets — whichever of Instance/AI-waypoint the duplicate
    /// turned out to be, only the matching registration actually does
    /// anything (each guards on its own `nil` check).
    private func duplicateSelected() {
        guard let renderer, let newIndex = renderer.duplicateSelectedObject() else { return }
        selectedIndex = newIndex
        refreshTransformFields()
        guard let undoManager else { return }
        undoManager.setActionName("Duplicate Object")
        Self.registerPlacementUndo(undoManager: undoManager, renderer: renderer, index: newIndex)
        Self.registerAIWaypointPlacementUndo(undoManager: undoManager, renderer: renderer, index: newIndex)
    }

    private static func registerPlacementUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, index: Int) {
        guard let snapshot = renderer.newInstanceInfo(at: index) else { return }
        undoManager.registerUndo(withTarget: renderer) { target in
            target.removeObject(at: index)
            undoManager.registerUndo(withTarget: target) { redoTarget in
                let newIndex = redoTarget.spawnInstance(objectID: snapshot.objectID, at: snapshot.worldPosition) ?? index
                registerPlacementUndo(undoManager: undoManager, renderer: redoTarget, index: newIndex)
            }
        }
    }
}

/// "Integrated Level Audio": every decoded `SoundEffect` in the level's
/// file, with a frictionless inline Play button — reuses `WAVEncoder`/
/// `PlaybackEndDelegate` (`SoundEffectInspectorView.swift`) rather than a
/// second audio-decoding path. Deliberately titled "Sound Effects in This
/// File", not "Background Music"/"Ambient Banks": `SoundEffectAsset` has
/// no field distinguishing those categories, and this format doesn't
/// record which chunk a level's music actually comes from — labeling them
/// by role would be presenting a guess as decoded data.
private struct LevelAudioPanel: View {
    let sounds: [(node: ChunkNode, sound: SoundEffectAsset)]
    @State private var playingNodeID: UUID?
    @State private var player: AVAudioPlayer?
    @State private var playerDelegate: PlaybackEndDelegate?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chunk Audio").font(.headline)
            Text("Sound effects in this file (\(sounds.count)) — not categorized as BGM/ambient, since nothing in the decoded data distinguishes those roles.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(sounds, id: \.node.id) { entry in
                HStack {
                    Button {
                        toggle(entry)
                    } label: {
                        Image(systemName: playingNodeID == entry.node.id ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(entry.sound.pcmSamples.isEmpty)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.node.displayName).font(.caption).lineLimit(1)
                        Text(String(format: "%.2fs · %d Hz", entry.sound.durationSeconds, entry.sound.sampleRateHz))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .onDisappear { player?.stop() }
    }

    private func toggle(_ entry: (node: ChunkNode, sound: SoundEffectAsset)) {
        if playingNodeID == entry.node.id {
            player?.stop()
            playingNodeID = nil
            return
        }
        guard !entry.sound.pcmSamples.isEmpty else { return }
        let wav = WAVEncoder.encode(pcm: entry.sound.pcmSamples, sampleRateHz: entry.sound.sampleRateHz)
        guard let newPlayer = try? AVAudioPlayer(data: wav) else {
            playingNodeID = nil
            return
        }
        let delegate = PlaybackEndDelegate { playingNodeID = nil }
        newPlayer.delegate = delegate
        playerDelegate = delegate
        player = newPlayer
        newPlayer.prepareToPlay()
        playingNodeID = newPlayer.play() ? entry.node.id : nil
    }
}

/// "The Forge Palette: Directory Asset Placement" (Part 4C) — a
/// categorized, searchable directory of every named `ObjectID`
/// (`DefaultObjectID`, ported from the reference tool's own enum) a new
/// `Instance` could be spawned as. Picking an entry arms placement mode
/// (`onArm`, wired to `LevelViewerRenderer.pendingPlacementObjectID` by the
/// caller) rather than placing anything itself — this view has no opinion
/// about *where* in the 3D world the next click lands.
private struct ForgePaletteView: View {
    let onArm: (UInt16, String) -> Void

    @State private var searchText = ""
    @State private var selectedCategory: DefaultObjectID.Category?

    private var filteredEntries: [(id: UInt16, name: String)] {
        DefaultObjectID.names
            .filter { selectedCategory == nil || DefaultObjectID.category(forName: $0.value) == selectedCategory }
            .filter { searchText.isEmpty || $0.value.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.value < $1.value }
            .map { (id: $0.key, name: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Forge Palette", systemImage: "hammer.fill").font(.headline)
            Text("Pick an object, then click in the viewport to place a brand-new Instance of it. Categories are a best-effort grouping by name text, not verified game data — see the panel's own tooltip.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("This build has no decoded game-logic data that classifies what an object actually is (hazard/pickup/enemy/prop) — these buckets are pattern-matched from the object's own name text.")

            TextField("Search objects…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            Picker("Category", selection: $selectedCategory) {
                Text("All").tag(DefaultObjectID.Category?.none)
                ForEach(DefaultObjectID.Category.allCases) { category in
                    Text(category.rawValue).tag(DefaultObjectID.Category?.some(category))
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            List(filteredEntries, id: \.id) { entry in
                Button {
                    onArm(entry.id, entry.name)
                } label: {
                    HStack {
                        Text(entry.name).lineLimit(1).font(.caption)
                        Spacer()
                        Text("#\(entry.id)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(height: 220)
            .listStyle(.bordered)
        }
    }
}
