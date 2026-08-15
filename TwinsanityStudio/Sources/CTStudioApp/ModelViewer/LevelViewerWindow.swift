import SwiftUI
import AppKit
import simd
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
    public var placements: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset)]
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
    /// "Collision / Ground Floor": the level's real, decoded collision
    /// mesh(es) — the actual walkable ground, previously never rendered
    /// anywhere in this Level Viewer (only scattered decorative scenery
    /// props were), which is what made a real level look like scattered
    /// pieces with massive gaps between them. See `WorkspaceViewModel.
    /// collisionMeshRecords`'s doc comment.
    public var collisionMeshes: [(node: ChunkNode, mesh: CollisionMesh)]

    public init(
        scenery: SceneryAsset,
        placements: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset)],
        instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)] = [],
        resolvedInstanceAssets: [UUID: ResolvedModelAsset] = [:],
        assetIndex: GraphicsAssetIndex = GraphicsAssetIndex(),
        defaultAssetIndex: GraphicsAssetIndex = GraphicsAssetIndex(),
        triggers: [(node: ChunkNode, trigger: TriggerVolume)] = [],
        cameras: [(node: ChunkNode, camera: PlacedCamera)] = [],
        sounds: [(node: ChunkNode, sound: SoundEffectAsset)] = [],
        chunkLinks: [(node: ChunkNode, link: ChunkLink)] = [],
        aiPositions: [(node: ChunkNode, marker: AIPositionMarker)] = [],
        aiPaths: [(node: ChunkNode, path: AIPathRecord)] = [],
        collisionMeshes: [(node: ChunkNode, mesh: CollisionMesh)] = []
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
        self.collisionMeshes = collisionMeshes
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
        case .geometryOnly: return [.scenery, .collision]
        case .populated: return Set(SceneLayer.allCases)
        }
    }
}

/// "Halo Reach Forge / Minecraft"-style mode rail: instead of every panel
/// stacked in one long scroll (the pre-overhaul layout — ~15 panels, a
/// real level's object count alone runs into the hundreds), a beginner
/// picks one task at a time and only sees the controls for it. The
/// current-selection tools (Transform/gizmo, the selected object's own
/// inspector, the Objects list) stay pinned below the rail regardless of
/// mode — every mode still needs "what am I looking at right now."
enum LevelEditorMode: String, CaseIterable, Identifiable {
    case select, place, terrain, ai, audio, advanced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .select: return "Select"
        case .place: return "Place"
        case .terrain: return "Terrain"
        case .ai: return "AI"
        case .audio: return "Audio"
        case .advanced: return "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .place: return "hammer.fill"
        case .terrain: return "square.grid.3x3.fill"
        case .ai: return "point.3.connected.trianglepath.dotted"
        case .audio: return "speaker.wave.2.fill"
        case .advanced: return "ellipsis.circle.fill"
        }
    }

    var helpText: String {
        switch self {
        case .select: return "Level stats and save"
        case .place: return "Forge Palette — place new Instances, Triggers, and Cameras"
        case .terrain: return "Scene layer visibility and view mode"
        case .ai: return "AI waypoints and paths"
        case .audio: return "Chunk audio and scripted-trigger events"
        case .advanced: return "Chunk links and cross-engine (Wrath of Cortex) data"
        }
    }
}

/// "Numbered Hotbar (1-9)": one Forge Palette entry pinned to a slot.
struct HotbarEntry: Equatable {
    let objectID: UInt16
    let name: String
}

struct LevelViewerWindow: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.undoManager) private var undoManager
    let context: LevelViewerContext

    @State private var renderer: LevelViewerRenderer?
    @State private var selectedIndex: Int?
    /// "Collapsible Sidebar Sections" (QoL): every list-heavy panel below
    /// starts collapsed — a real level's object count runs into the
    /// hundreds, and previously there was no way to reach the panels
    /// beneath it without scrolling straight past all of them first.
    @State private var isObjectListExpanded = false
    @State private var isLevelEventsExpanded = false
    @State private var isAIPathsExpanded = false
    @State private var viewMode: LevelViewMode = .populated
    /// Collision starts hidden — real, opaque ground-floor fill is useful
    /// for confirming a level's actual walkable surface, but as a default
    /// it visually dominates every other layer and most editing work
    /// doesn't need it. Toggle it back on any time from the Terrain panel;
    /// the "Fully Populated" preset also still includes it, since that
    /// button is an explicit "show me everything" request.
    @State private var layerVisibility: Set<SceneLayer> = Set(SceneLayer.allCases).subtracting([.collision])
    /// "Halo Reach Forge / Minecraft"-style mode rail — see
    /// `LevelEditorMode`'s own doc comment.
    @State private var editorMode: LevelEditorMode = .select
    /// One search field drives both the Object list (filters it directly)
    /// and the Forge Palette (forwarded through its own `searchText`
    /// binding) — a beginner shouldn't need to know which of six mode
    /// tabs a specific object or placeable lives under before they can
    /// search for it.
    @State private var sidebarSearchText = ""
    @State private var isControlsLegendExpanded = false
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
    @State private var magnetSnapEnabled = true
    @State private var rotationSnapDegrees: Double = 15.0
    @State private var isDropTargeted = false
    /// "The Forge Palette" (Part 4C): non-nil while a palette pick is armed
    /// and waiting for the viewport click that places it — mirrors
    /// `renderer.pendingPlacementObjectID` into SwiftUI `@State` the same
    /// way `selectedIndex` mirrors `renderer.selectedObjectIndex`, since
    /// the renderer itself is a plain class AppKit mutates directly, not an
    /// `ObservableObject`.
    @State private var armedPlacement: (objectID: UInt16, name: String)?
    /// "Numbered Hotbar (1-9)": what's pinned to each of the 9 slots —
    /// `nil` for an empty slot. Session-only, like `armedPlacement`; not
    /// persisted to disk. Pinned from the Forge Palette (a small pin
    /// button per row); pressing 1-9 in the viewport arms whatever's in
    /// that slot, the same as clicking the palette row directly.
    @State private var hotbarSlots: [HotbarEntry?] = Array(repeating: nil, count: 9)
    /// "Radial Marking Menu (hold Q)": non-nil while the menu is open, the
    /// AppKit view-point (bottom-left origin, matching `MetalModelView`'s
    /// own coordinate space) where Q went down — the menu's own center.
    /// `nil` hides the overlay entirely.
    @State private var markingMenuCenter: CGPoint?
    /// The cursor's current position (same coordinate space as
    /// `markingMenuCenter`), updated on every `mouseMoved` while the menu
    /// is held — the delta between the two drives which slice highlights.
    @State private var markingMenuCurrentPoint: CGPoint = .zero
    /// "Procedural Brush" (roadmap 8.6) — see `scatterSelected`'s doc
    /// comment.
    @State private var scatterCount: Double = 8
    @State private var scatterRadius: Double = 3
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
            let isDemoCameraCollection = referenceNodeForFileOps.flatMap { workspace.cameraCollectionIsDemo(inSameFileAs: $0) } ?? false
            renderer = LevelViewerRenderer(
                placements: context.placements,
                instanceMarkers: context.instanceMarkers,
                resolvedInstanceAssets: context.resolvedInstanceAssets,
                assetIndex: context.assetIndex,
                defaultAssetIndex: context.defaultAssetIndex,
                triggers: context.triggers,
                cameras: context.cameras,
                chunkLinks: context.chunkLinks,
                aiPositions: context.aiPositions,
                collisionMeshes: context.collisionMeshes.map(\.mesh),
                isDemoCameraCollection: isDemoCameraCollection
            )
            renderer?.snapToGrid = snapToGrid
            renderer?.gridSize = Float(gridSize)
            renderer?.magnetSnapEnabled = magnetSnapEnabled
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

    /// "Numbered Hotbar (1-9)": pins an entry into the first empty slot,
    /// or replaces slot 1 once every slot is full — the same "keep going,
    /// don't block" posture as everything else in this palette (no error
    /// state for "hotbar is full," just the oldest/first pin gets bumped).
    private func pinToHotbar(objectID: UInt16, name: String) {
        if let emptyIndex = hotbarSlots.firstIndex(where: { $0 == nil }) {
            hotbarSlots[emptyIndex] = HotbarEntry(objectID: objectID, name: name)
        } else {
            hotbarSlots[0] = HotbarEntry(objectID: objectID, name: name)
        }
    }

    /// Arms whatever's pinned to `slot` (1-9) for placement, identically to
    /// clicking that entry in the Forge Palette — including switching to
    /// Place mode, so pressing a hotbar key works from any sidebar tab, not
    /// just while the palette is already open.
    private func armHotbarSlot(_ slot: Int) {
        guard hotbarSlots.indices.contains(slot - 1), let entry = hotbarSlots[slot - 1] else { return }
        editorMode = .place
        armedPlacement = (entry.objectID, entry.name)
        renderer?.pendingPlacementObjectID = entry.objectID
    }

    /// "Radial Marking Menu (hold Q)": generic, always-available quick
    /// actions on the current selection — the same four actions
    /// `selectionHUD` already exposes, reachable without moving the mouse
    /// to the corner of the viewport. Not layer-specific (a Trigger vs. an
    /// Instance vs. a Camera all get the same four slices) since this
    /// build has no decoded game-logic data to make a genuinely different
    /// per-type action set honest, rather than invented.
    private struct MarkingMenuAction {
        let icon: String
        let label: String
        let isEnabled: Bool
        let perform: () -> Void
    }

    private var markingMenuActions: [MarkingMenuAction] {
        [
            MarkingMenuAction(icon: "plus.square.on.square", label: "Duplicate", isEnabled: canDuplicateSelected) { duplicateSelected() },
            MarkingMenuAction(icon: "trash", label: "Delete", isEnabled: canDeleteSelected) { deleteSelected() },
            MarkingMenuAction(icon: "camera.viewfinder", label: "Copy Viewer Pos", isEnabled: selectedIndex != nil) { copyViewerPositionToSelected() },
            MarkingMenuAction(icon: "viewfinder", label: "Frame Selection", isEnabled: true) { renderer?.resetView() },
        ]
    }

    /// Which slice the cursor is currently over, or `nil` in the small
    /// dead zone right at the center (so a barely-moved cursor doesn't
    /// commit to whatever slice happens to contain the origin). A free
    /// function (not a computed property) specifically so it's directly
    /// unit-testable without a live view/`@State` — this codebase has been
    /// burned repeatedly this session by rotation/angle sign errors that
    /// "looked right" under hand-tracing alone, so this one gets a real
    /// test instead of trusting the derivation.
    ///
    /// Both points are in AppKit's own y-up view space; the angle math
    /// stays entirely in that space and converts to screen-clockwise
    /// internally (`dyScreen = -dy`) — the caller never needs to think
    /// about SwiftUI's y-down drawing coordinates, only `markingMenuOverlay`'s
    /// drawing code does, and that's kept in the same convention (clockwise
    /// from straight up / 12 o'clock) so the highlighted slice always
    /// visually agrees with where the cursor actually is.
    static func markingMenuSliceIndex(center: CGPoint, current: CGPoint, sliceCount: Int, deadZoneRadius: Double = 14) -> Int? {
        guard sliceCount > 0 else { return nil }
        let dx = Double(current.x - center.x)
        let dyScreen = -Double(current.y - center.y) // AppKit is y-up; screen-clockwise math is y-down
        guard hypot(dx, dyScreen) > deadZoneRadius else { return nil }
        let theta = atan2(dyScreen, dx) // 0 = east, -pi/2 = up (north); increasing = clockwise on screen
        let sliceSize = 2 * Double.pi / Double(sliceCount)
        var shifted = (theta + .pi / 2 + sliceSize / 2).truncatingRemainder(dividingBy: 2 * .pi)
        if shifted < 0 { shifted += 2 * .pi }
        return Int(shifted / sliceSize) % sliceCount
    }

    private var markingMenuHighlightedIndex: Int? {
        guard let markingMenuCenter else { return nil }
        return Self.markingMenuSliceIndex(center: markingMenuCenter, current: markingMenuCurrentPoint, sliceCount: markingMenuActions.count)
    }

    private func executeHighlightedMarkingMenuAction() {
        guard let index = markingMenuHighlightedIndex, markingMenuActions.indices.contains(index) else { return }
        let action = markingMenuActions[index]
        guard action.isEnabled else { return }
        action.perform()
    }

    /// Radial pie overlay, positioned via `GeometryReader` so it can
    /// convert `markingMenuCenter`'s AppKit (y-up) point into this
    /// overlay's own SwiftUI (y-down) drawing space using the viewport's
    /// actual current size, rather than assuming one.
    @ViewBuilder
    private var markingMenuOverlay: some View {
        if let markingMenuCenter {
            GeometryReader { geo in
                let center = CGPoint(x: markingMenuCenter.x, y: geo.size.height - markingMenuCenter.y)
                let radius: CGFloat = 70
                let highlighted = markingMenuHighlightedIndex
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: radius * 2 + 44, height: radius * 2 + 44)
                        .position(center)
                    ForEach(Array(markingMenuActions.enumerated()), id: \.offset) { index, action in
                        let sliceAngle = 2 * Double.pi / Double(markingMenuActions.count)
                        let angle = -Double.pi / 2 + Double(index) * sliceAngle
                        let itemCenter = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
                        VStack(spacing: 3) {
                            Image(systemName: action.icon)
                            Text(action.label).font(.caption2)
                        }
                        .foregroundStyle(action.isEnabled ? .white : .white.opacity(0.35))
                        .padding(8)
                        .background(Circle().fill(highlighted == index ? Color.accentColor : Color.black.opacity(0.55)))
                        .position(itemCenter)
                    }
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 6, height: 6)
                        .position(center)
                }
            }
            .allowsHitTesting(false)
        }
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
                        },
                        onHotbarSlotPressed: { slot in armHotbarSlot(slot) },
                        onMarkingMenuBegan: { point in
                            markingMenuCenter = point
                            markingMenuCurrentPoint = point
                        },
                        onMarkingMenuMoved: { point in markingMenuCurrentPoint = point },
                        onMarkingMenuEnded: {
                            executeHighlightedMarkingMenuAction()
                            markingMenuCenter = nil
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
                        Text("Drag to orbit · Scroll to zoom · Drag a handle or use arrow keys to \(gizmoMode == .translate ? "move" : gizmoMode == .rotate ? "rotate" : "scale") the selection · W/E/R to switch · F to frame")
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
                    if selectedIndex != nil {
                        selectionHUD
                            .padding(10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                    hotbarRow
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    markingMenuOverlay
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

    /// "Halo Reach Forge / Minecraft"-style quick-action bar: the most
    /// common actions on the current selection (duplicate, delete, copy
    /// the camera's position onto it), reachable without touching the
    /// sidebar at all — Forge's own bottom action bar is the direct
    /// inspiration. The sidebar's Transform panel still has the same
    /// three actions (plus precise numeric fields), so nothing here is a
    /// second, diverging implementation — every button below calls the
    /// exact same functions the sidebar buttons do.
    private var selectionHUD: some View {
        HStack(spacing: 10) {
            Button {
                copyViewerPositionToSelected()
            } label: {
                Image(systemName: "camera.viewfinder")
            }
            .help("Copy Viewer Position")

            Button {
                duplicateSelected()
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .disabled(!canDuplicateSelected)
            .help("Duplicate (⌘D)")

            Button(role: .destructive) {
                deleteSelected()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(!canDeleteSelected)
            .help("Delete")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// "Numbered Hotbar (1-9)" — always-visible bottom-center strip, the
    /// Minecraft/Forge-style quick-select this Level Viewer never had:
    /// pin an entry from the Forge Palette, then press its digit anywhere
    /// in the viewport to arm it instantly, without opening the palette
    /// list and scrolling to find it again.
    private var hotbarRow: some View {
        HStack(spacing: 4) {
            ForEach(1...9, id: \.self) { slot in
                let entry = hotbarSlots[slot - 1]
                Button {
                    armHotbarSlot(slot)
                } label: {
                    VStack(spacing: 2) {
                        Text("\(slot)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        if let entry {
                            Text(entry.name)
                                .font(.caption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        } else {
                            Image(systemName: "circle.dashed")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 52, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(entry == nil)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(armedPlacement?.objectID == entry?.objectID && entry != nil ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                .help(entry != nil ? "Press \(slot) to place \(entry!.name)" : "Empty — pin an object here from the Forge Palette (Place mode)")
            }
        }
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(context.scenery.chunkName.isEmpty ? "Chunk" : context.scenery.chunkName)
                    .font(.title3.bold())

                TextField("Search objects & placeables…", text: $sidebarSearchText)
                    .textFieldStyle(.roundedBorder)
                    .help("Filters the Objects list below and the Forge Palette (Place tab) at once — you don't need to know which tab something lives under to find it.")

                controlsLegendPanel

                modeRail

                modeContent

                Divider()

                // Always-pinned regardless of mode — "what am I looking at
                // right now" is relevant no matter which task tab is
                // active. This is the single biggest change from the
                // pre-overhaul layout: these three used to be three of
                // ~15 panels stacked in one long scroll: now every mode
                // still shows them without the user hunting for them.
                gizmoControls

                if let node = renderer?.selectedSourceNode {
                    Divider()
                    selectedObjectInspector(node: node)
                }

                Divider()

                objectList
            }
            .padding(16)
        }
    }

    /// Icon-button row switching which task-specific panel shows below —
    /// see `LevelEditorMode`'s own doc comment for the design rationale.
    private var modeRail: some View {
        HStack(spacing: 4) {
            ForEach(LevelEditorMode.allCases) { mode in
                Button {
                    editorMode = mode
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 15))
                        Text(mode.displayName).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(editorMode == mode ? Color.accentColor : Color.secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(editorMode == mode ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .help(mode.helpText)
            }
        }
    }

    @ViewBuilder
    private var modeContent: some View {
        switch editorMode {
        case .select: selectModeContent
        case .place: placeModeContent
        case .terrain: modeAndLayersPanel
        case .ai: aiModeContent
        case .audio: audioModeContent
        case .advanced: advancedModeContent
        }
    }

    /// "Select" (default mode): level-wide stats and the save action —
    /// the one thing every other mode eventually needs regardless of what
    /// you were just placing/adjusting.
    @ViewBuilder
    private var selectModeContent: some View {
        Form {
            LabeledContent("Placements in tree", value: "\(context.scenery.placements.count)")
            LabeledContent("Scenery resolved", value: "\(context.placements.count)")
            LabeledContent("Instance markers", value: "\(context.instanceMarkers.count)")
            LabeledContent("Triggers", value: "\(context.triggers.count)")
            LabeledContent("Cameras", value: "\(context.cameras.count)")
        }
        .formStyle(.grouped)

        Text("Scenery objects are drawn at their correct world position, rotation, and scale, decoded from the chunk data — scenery has no write path yet (in-session sandbox only). The amber cubes are Instance records (crate/enemy/platform placements) — their position/rotation is real, live-editable with the gizmo, and \"Save Chunk Overrides…\" below writes it back to a copy of the file. Green/cyan wireframe boxes are Triggers/Cameras — click to select and inspect; no 3D gizmo yet, but their inspector panel below has real, writable position/size/rotation fields with their own \"Save Edited Copy…\" button. The small magenta boxes along a camera's path are its real spline/path control points — click and drag one with the gizmo like any other object; \"Save Chunk Overrides…\" patches each moved point's own 16 bytes straight into the file, without needing to re-encode the rest of that Camera record. Inserting or removing a control point isn't supported yet — only moving an existing one.")
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
    }

    /// "Place" mode: the Forge Palette plus "Add Trigger"/"Add Camera" —
    /// every way to bring a brand-new object into the level, in one place.
    @ViewBuilder
    private var placeModeContent: some View {
        ForgePaletteView(
            placedThisSession: renderer?.pendingNewInstances.count ?? 0,
            canResolve: { renderer?.canResolveObjectID($0) },
            resolveForThumbnail: { renderer?.resolvedAsset(forObjectID: $0) },
            searchText: $sidebarSearchText,
            onPin: { objectID, name in pinToHotbar(objectID: objectID, name: name) }
        ) { objectID, name in
            armedPlacement = (objectID, name)
            renderer?.pendingPlacementObjectID = objectID
        }
        Divider()
        addTriggerCameraPanel
    }

    @ViewBuilder
    private var aiModeContent: some View {
        if !context.aiPositions.isEmpty || !context.aiPaths.isEmpty {
            aiWaypointsPanel
            if !context.aiPaths.isEmpty {
                Divider()
                aiPathsPanel
            }
        } else {
            Text("No AI waypoints or paths in this chunk.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var audioModeContent: some View {
        if !context.sounds.isEmpty {
            LevelAudioPanel(sounds: context.sounds)
        }
        if !context.triggers.isEmpty || hasScriptedInstances {
            if !context.sounds.isEmpty { Divider() }
            levelEventsPanel
        }
        if context.sounds.isEmpty && context.triggers.isEmpty && !hasScriptedInstances {
            Text("No audio or scripted trigger events in this chunk.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var advancedModeContent: some View {
        if !context.chunkLinks.isEmpty {
            chunkLinksPanel
            Divider()
        }
        crossEngineDataPanel
    }

    /// "On-Screen Control Legend" (QoL): the viewport's own single
    /// rotating caption line only ever shows the *current* gizmo mode's
    /// shortcut — this lists every camera/gizmo/placement shortcut at
    /// once, collapsed by default so it doesn't compete for space with
    /// the panels a returning user already knows how to find.
    private var controlsLegendPanel: some View {
        DisclosureGroup(isExpanded: $isControlsLegendExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                controlLegendRow("Drag", "Orbit the camera")
                controlLegendRow("Scroll", "Zoom (or fly speed, in Free Camera)")
                controlLegendRow("W / E / R", "Move / Rotate / Scale gizmo")
                controlLegendRow("Arrow keys", "Nudge the selection along X/Z")
                controlLegendRow("⇧ + ↑ / ↓", "Nudge the selection along Y")
                controlLegendRow("F", "Frame the current selection")
                controlLegendRow("1-9", "Place whatever's pinned to that hotbar slot")
                controlLegendRow("Hold Q", "Radial marking menu — release on a slice to run it")
                controlLegendRow("⌘D", "Duplicate the selected object")
                controlLegendRow("Delete", "Delete the selected object")
                controlLegendRow("⌘Z / ⌘⇧Z", "Undo / Redo")
                controlLegendRow("WASD + Q/E", "Fly (Free Camera mode only)")
                controlLegendRow("Right-drag", "Look around (Free Camera mode only)")
            }
            .padding(.top, 4)
        } label: {
            Label("Controls", systemImage: "keyboard").font(.subheadline.bold())
        }
    }

    private func controlLegendRow(_ key: String, _ action: String) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.caption.monospaced().bold())
                .frame(width: 90, alignment: .leading)
            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Toggle(layerLabel(for: layer), isOn: layerBinding(for: layer))
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
            .disabled(context.instanceMarkers.isEmpty && context.triggers.count < 2 && context.cameras.isEmpty)
            .help("Reassign which real object each placement resolves to, batch-edit triggers that share the same arguments, apply verified Gameplay Mods, or unlock placed cameras.")
        }
        .sheet(isPresented: $isRecipeBookPresented) {
            if let referenceNode = referenceNodeForFileOps {
                RecipeBookView(
                    instanceMarkers: context.instanceMarkers,
                    resolvedInstanceAssets: context.resolvedInstanceAssets,
                    triggers: context.triggers,
                    cameras: context.cameras,
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

    /// Appends a real record count to layers where "I see nothing" is
    /// ambiguous between "this chunk genuinely has none of these" and "the
    /// layer toggle above is off" — the two indistinguishable-looking
    /// outcomes behind a real, recurring bug report. The count is always
    /// shown, on or off, so toggling a layer off never makes its count
    /// vanish along with it.
    private func layerLabel(for layer: SceneLayer) -> String {
        let count: Int?
        switch layer {
        case .actors: count = context.instanceMarkers.count
        case .triggers: count = context.triggers.count
        case .cameras: count = context.cameras.count
        case .aiWaypoints: count = context.aiPositions.count
        case .collision: count = context.collisionMeshes.count
        case .scenery, .chunkBoundaries, .linkedChunks, .crossEngine: count = nil
        }
        guard let count else { return layer.displayName }
        return "\(layer.displayName) (\(count))"
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
            selectedObjectIdentityHeader(node: node)
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

    /// A clear "what is this, and what's it called" line above every
    /// per-record-type inspector below — real object names come from
    /// `DefaultObjectID.names` (the same verified id->name table the Forge
    /// Palette already uses), never invented; a raw `objectID` shows on
    /// its own only when this build has no name for it.
    @ViewBuilder
    private func selectedObjectIdentityHeader(node: ChunkNode) -> some View {
        let identity: (icon: String, kind: String, name: String) = {
            switch node.payload {
            case .instance(let instance):
                let name = DefaultObjectID.names[instance.objectID] ?? "Unnamed Object #\(instance.objectID)"
                return ("cube.transparent.fill", "Actor / Prop Instance", name)
            case .trigger(let trigger):
                return ("square.dashed", "Trigger Volume", "Trigger #\(trigger.id)")
            case .camera(let camera):
                return ("video.fill", "Camera", "Camera #\(camera.id)")
            case .aiPosition(let marker):
                let typeName = marker.nodeType.map { "\($0)" } ?? "Unrecognized Type"
                return ("figure.walk", "AI Waypoint", "Waypoint #\(marker.id) (\(typeName))")
            default:
                return ("questionmark.square.dashed", "Unknown Record", "—")
            }
        }()
        HStack(spacing: 6) {
            Image(systemName: identity.icon).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(identity.name).font(.callout.bold())
                Text(identity.kind).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
        DisclosureGroup(isExpanded: $isLevelEventsExpanded) {
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
        } label: {
            Text("Chunk Events").font(.headline)
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
            // "Coordinate-System Overhaul": `chunkMatrix`'s translation row
            // is raw on-disk data, same as every other position this build
            // decodes — needs the same world-space X mirror
            // `result.placements` already got via the (now-corrected)
            // `SceneryModelPlacement.worldTransform`, or a stitched
            // neighbor lands offset in the wrong direction along X.
            let offset = link.chunkMatrix.count > 3
                ? ModelViewerRenderer.mirroredWorldPosition(SIMD3(link.chunkMatrix[3].x, link.chunkMatrix[3].y, link.chunkMatrix[3].z))
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

            Toggle("Magnet Snap", isOn: $magnetSnapEnabled)
                .toggleStyle(.checkbox)
                .help("When on, dragging a piece close to another placement's position snaps it into exact alignment on that axis — catches spacing a grid snap alone can't.")
                .onChange(of: magnetSnapEnabled) { _, newValue in renderer?.magnetSnapEnabled = newValue }

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
                Button {
                    copyViewerPositionToSelected()
                } label: {
                    Label("Copy Viewer Position", systemImage: "camera.viewfinder")
                }
                .controlSize(.small)
                .help("Set the selected object's position to the camera's current world-space position — the same convenience the original editor's Position/AIPosition/Instance editors offer.")
                transformFieldGroup(title: "Rotation °", x: $rotationX, y: $rotationY, z: $rotationZ, apply: applyRotationFields)
                transformFieldGroup(title: "Scale", x: $scaleX, y: $scaleY, z: $scaleZ, apply: applyScaleFields)
                HStack {
                    Button {
                        duplicateSelected()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(!canDuplicateSelected)
                    .help(canDuplicateSelected
                        ? "Duplicate the selected object, with real write-back to disk on save."
                        : "Only Actor/Instance placements, AI waypoints, Triggers, and Cameras can be duplicated — scenery has no write path back to the file yet, and a camera's own spline/path control points duplicate with the whole camera, not individually.")

                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(!canDeleteSelected)
                    .help(canDeleteSelected
                        ? "Delete the selected object. Undo with ⌘Z; the deletion only persists to disk once you Save Chunk Overrides…"
                        : "Only Actor/Instance placements, AI waypoints, Triggers, and Cameras can be deleted — scenery has no write path back to the file yet, and a camera's own spline/path control points aren't independently deletable.")
                }

                if canScatterSelected {
                    Divider()
                    Label("Procedural Brush", systemImage: "wind").font(.caption.bold())
                    HStack {
                        Text("Count"); Stepper(value: $scatterCount, in: 1...50) { Text("\(Int(scatterCount))") }
                    }
                    HStack {
                        Text("Radius"); Stepper(value: $scatterRadius, in: 0.5...50, step: 0.5) { Text(String(format: "%.1f", scatterRadius)) }
                    }
                    Button {
                        scatterSelected()
                    } label: {
                        Label("Scatter \(Int(scatterCount))…", systemImage: "wind")
                    }
                    Text("Set-dresses the level: scatters \(Int(scatterCount)) more real copies of the selected object at random positions/rotations within \(String(format: "%.1f", scatterRadius))m — each one a genuine new Instance record on save, through the same pipeline Duplicate uses.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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

    /// "Add Trigger"/"Add Camera": closes the parity gap the original
    /// editor's `Menu_AddNew` has for these two record types — real, brand-
    /// new records inserted via `ChunkSectionInserter` on save, same as
    /// "Add Waypoint."
    private var addTriggerCameraPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add Objects").font(.headline)
            Text("Places a brand-new Trigger or Camera at the level's visual center — drag it into position, then Save Chunk Overrides… to make it real.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button("Add Trigger") { addTrigger() }
                Button("Add Camera") { addCamera() }
            }
        }
    }

    private func addTrigger() {
        guard let renderer, let index = renderer.spawnTrigger() else { return }
        selectedIndex = index
        refreshTransformFields()
        guard let undoManager else { return }
        undoManager.setActionName("Add Trigger")
        Self.registerTriggerPlacementUndo(undoManager: undoManager, renderer: renderer, index: index)
    }

    private func addCamera() {
        guard let renderer, let index = renderer.spawnCamera() else { return }
        selectedIndex = index
        refreshTransformFields()
        guard let undoManager else { return }
        undoManager.setActionName("Add Camera")
        Self.registerCameraPlacementUndo(undoManager: undoManager, renderer: renderer, index: index)
    }

    private static func registerTriggerPlacementUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, index: Int) {
        guard let worldPosition = renderer.newTriggerInfo(at: index) else { return }
        undoManager.registerUndo(withTarget: renderer) { target in
            target.removeObject(at: index)
            undoManager.registerUndo(withTarget: target) { redoTarget in
                let newIndex = redoTarget.spawnTrigger(at: worldPosition) ?? index
                registerTriggerPlacementUndo(undoManager: undoManager, renderer: redoTarget, index: newIndex)
            }
        }
    }

    private static func registerCameraPlacementUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, index: Int) {
        guard let worldPosition = renderer.newCameraInfo(at: index) else { return }
        undoManager.registerUndo(withTarget: renderer) { target in
            target.removeObject(at: index)
            undoManager.registerUndo(withTarget: target) { redoTarget in
                let newIndex = redoTarget.spawnCamera(at: worldPosition) ?? index
                registerCameraPlacementUndo(undoManager: undoManager, renderer: redoTarget, index: newIndex)
            }
        }
    }

    private var canDeleteSelected: Bool {
        guard let renderer, let selectedIndex else { return false }
        return renderer.canDelete(at: selectedIndex)
    }

    /// Deletes the selected object through `LevelViewerRenderer.deleteObject`
    /// (real removal from disk on save, for a real record — see that
    /// function's own doc comment) and registers a recursive undo/redo
    /// step, same shape as `registerTransformUndo`/`registerPlacementUndo`:
    /// undo re-inserts the exact removed value via `restoreObject`; redo
    /// (registered as the undo *of that* restore) deletes it again.
    private func deleteSelected() {
        guard let renderer, let index = selectedIndex, let snapshot = renderer.deleteObject(at: index) else { return }
        selectedIndex = nil
        refreshTransformFields()
        guard let undoManager else { return }
        undoManager.setActionName("Delete Object")
        Self.registerDeleteUndo(undoManager: undoManager, renderer: renderer, index: index, snapshot: snapshot)
    }

    private static func registerDeleteUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, index: Int, snapshot: LevelViewerRenderer.RemovedObjectSnapshot) {
        undoManager.registerUndo(withTarget: renderer) { target in
            target.restoreObject(snapshot, at: index)
            undoManager.registerUndo(withTarget: target) { redoTarget in
                guard let redoSnapshot = redoTarget.deleteObject(at: index) else { return }
                registerDeleteUndo(undoManager: undoManager, renderer: redoTarget, index: index, snapshot: redoSnapshot)
            }
        }
    }

    /// "Copy Viewer Position": the same convenience the original editor's
    /// Position/AIPosition/Instance editors offer — grabs the camera's
    /// current real-world eye position into the selected object's
    /// position field, through the same undo path every other position
    /// edit already uses.
    private func copyViewerPositionToSelected() {
        guard let renderer, selectedIndex != nil else { return }
        let previousSnapshot = currentSnapshot()
        renderer.setSelectedPosition(to: renderer.cameraEyeWorldPosition)
        refreshTransformFields()
        registerUndo(from: previousSnapshot)
    }

    /// "AI Pathfinding/Navmesh Editor" (roadmap 5.1): the real `AIPath`
    /// records in this file — no position of their own (see
    /// `AIPathRecord`'s doc comment), so a factual list rather than a
    /// scene-layer overlay. `AIPosition` waypoints render in the viewport
    /// instead (the "AI Waypoints" scene layer).
    private var aiPathsPanel: some View {
        DisclosureGroup(isExpanded: $isAIPathsExpanded) {
            Text("Real AIPath records — 5 raw arguments each, no confirmed link to any AI Waypoint (the reference tool's own editor doesn't interpret these either).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(context.aiPaths, id: \.node.id) { entry in
                Text("Path #\(entry.path.id): \(entry.path.args.map(String.init).joined(separator: ", "))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text("AI Paths (\(context.aiPaths.count))").font(.headline)
        }
    }

    /// Collapsed by default — a real level's object list runs into the
    /// hundreds, and a scene this size used to mean scrolling straight
    /// past everything below it just to reach the other sidebar panels.
    @ViewBuilder
    private var objectList: some View {
        let allSummaries = renderer?.objectSummaries ?? []
        let filteredSummaries = sidebarSearchText.isEmpty
            ? allSummaries
            : allSummaries.filter { $0.displayName.localizedCaseInsensitiveContains(sidebarSearchText) }
        DisclosureGroup(isExpanded: $isObjectListExpanded) {
            if filteredSummaries.isEmpty && !sidebarSearchText.isEmpty {
                Text("No objects match “\(sidebarSearchText)”.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(filteredSummaries, id: \.index) { summary in
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
        } label: {
            Text("Objects (\(renderer?.objectCount ?? 0))").font(.headline)
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
        let newTriggers = renderer.pendingNewTriggers
        let newCameras = renderer.pendingNewCameras
        let removedInstanceIDs = renderer.pendingRemovedInstanceIDs
        let removedTriggerIDs = renderer.pendingRemovedTriggerIDs
        let removedCameraIDs = renderer.pendingRemovedCameraIDs
        let removedAIPositionIDs = renderer.pendingRemovedAIPositionIDs
        guard !edits.isEmpty || !controlPointEdits.isEmpty || !newInstances.isEmpty || !newAIPositions.isEmpty
            || !newTriggers.isEmpty || !newCameras.isEmpty
            || !removedInstanceIDs.isEmpty || !removedTriggerIDs.isEmpty || !removedCameraIDs.isEmpty || !removedAIPositionIDs.isEmpty
        else { return }

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
            insertingNewTriggers: newTriggers,
            insertingNewCameras: newCameras,
            removingInstanceIDs: removedInstanceIDs,
            removingTriggerIDs: removedTriggerIDs,
            removingCameraIDs: removedCameraIDs,
            removingAIPositionIDs: removedAIPositionIDs,
            levelNode: referenceNode
        ) else { return }

        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(workspace.originalFileName(for: referenceNode) ?? "chunk")_edited.rm2",
            message: "Save the edited copy of this file, with every Instance/AI Waypoint/Camera control point's current position applied, every newly placed object/waypoint/trigger/camera added, and every deleted object removed. The original file on disk is not modified."
        ) else { return }
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                var summary = "Saved edited copy to \(url.lastPathComponent)"
                var parts: [String] = []
                if !edits.isEmpty { parts.append("\(edits.count) transform override(s)") }
                if !controlPointEdits.isEmpty { parts.append("\(controlPointEdits.count) camera control point(s)") }
                if !newInstances.isEmpty { parts.append("\(newInstances.count) newly placed object(s)") }
                if !newAIPositions.isEmpty { parts.append("\(newAIPositions.count) newly placed waypoint(s)") }
                if !newTriggers.isEmpty { parts.append("\(newTriggers.count) newly placed trigger(s)") }
                if !newCameras.isEmpty { parts.append("\(newCameras.count) newly placed camera(s)") }
                let removedTotal = removedInstanceIDs.count + removedTriggerIDs.count + removedCameraIDs.count + removedAIPositionIDs.count
                if removedTotal > 0 { parts.append("\(removedTotal) deleted object(s)") }
                summary += " with " + parts.joined(separator: " and ") + ". The original file was not modified."
                workspace.statusMessage = summary
            } catch {
                workspace.lastError = "Save failed: \(error)"
            }
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

    /// "Procedural Brush" (roadmap 8.6): only offered for a selected
    /// Actor/Instance placement — `LevelViewerRenderer.scatterAroundSelected`
    /// itself already scopes to that layer (the only one with a real spawn
    /// primitive), this just avoids showing controls that would silently
    /// no-op for scenery/trigger/camera/AI-waypoint selections.
    private var canScatterSelected: Bool {
        guard let renderer, let selectedIndex else { return false }
        return renderer.canDuplicate(at: selectedIndex) && renderer.selectedObjectLayer == .actors
    }

    private func scatterSelected() {
        guard let renderer else { return }
        let newIndices = renderer.scatterAroundSelected(count: Int(scatterCount), radius: Float(scatterRadius))
        guard !newIndices.isEmpty else { return }
        selectedIndex = newIndices.last
        refreshTransformFields()
        guard let undoManager else { return }
        undoManager.setActionName("Scatter \(newIndices.count) Objects")
        for index in newIndices {
            Self.registerPlacementUndo(undoManager: undoManager, renderer: renderer, index: index)
        }
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
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
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
        } label: {
            Text("Chunk Audio (\(sounds.count))").font(.headline)
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
    /// "Visual Item Memory Budget" (blueprint 6.1): a live count of new
    /// `Instance` placements armed via this palette in the current editing
    /// session (`ModelViewerRenderer.pendingNewInstances`, the same list
    /// "Save Chunk Overrides…" writes back). Deliberately *not* a
    /// budget-bar against a fixed ceiling — nothing in this codebase's
    /// reference material verifies a real per-chunk object-count limit the
    /// PS2 engine actually enforces, and this codebase's convention is to
    /// never fabricate a number like that from guesswork. This is Forge's
    /// "budget awareness" in the one honest form available: how much
    /// *you've* added, growing live as you place things, not a percentage
    /// against an invented cap.
    let placedThisSession: Int
    /// Whether `objectID` would resolve to real geometry in the level
    /// currently open — see `LevelViewerRenderer.canResolveObjectID`'s doc
    /// comment. `nil` means "renderer not ready yet," shown as available
    /// rather than flashing every entry as unresolvable before load
    /// finishes.
    let canResolve: (UInt16) -> Bool?
    /// "Drag-and-Drop Asset Palette & Tray" (roadmap 6.2): resolves an
    /// entry to the real geometry a thumbnail render needs — `nil` for the
    /// same reasons `canResolve` can be `nil`/`false` (renderer not ready
    /// yet, or this level's data genuinely has no geometry for that ID).
    let resolveForThumbnail: (UInt16) -> ResolvedModelAsset?
    /// Bound to the sidebar-wide search field (`LevelViewerWindow`'s own
    /// `sidebarSearchText`) — typing there filters this palette live even
    /// when "Place" isn't the active mode tab, and the palette's own
    /// search field below both reads and writes the same text, so either
    /// entry point stays in sync with the other. Declared before `onArm`
    /// so trailing-closure call syntax still works at the call site.
    @Binding var searchText: String
    /// "Numbered Hotbar (1-9)": pins this entry into the next free hotbar
    /// slot — a separate action from `onArm` (clicking the row itself
    /// still arms placement immediately, unchanged) so pinning doesn't
    /// require placing one first. Declared before `onArm` so `onArm` stays
    /// the trailing closure at the call site.
    let onPin: (UInt16, String) -> Void
    let onArm: (UInt16, String) -> Void

    @State private var selectedCategory: DefaultObjectID.Category?
    @State private var hideUnavailable = false
    /// Same cache/failure-set split `ModelsHubView` uses for its gallery
    /// thumbnails, keyed by `objectID` instead of a resolved asset's own
    /// `id` — a palette entry's thumbnail is looked up before any
    /// `ResolvedModelAsset` exists for it.
    @State private var thumbnailCache: [UInt16: NSImage] = [:]
    @State private var failedThumbnailIDs: Set<UInt16> = []

    private var filteredEntries: [(id: UInt16, name: String)] {
        DefaultObjectID.names
            .filter { selectedCategory == nil || DefaultObjectID.category(forName: $0.value) == selectedCategory }
            .filter { searchText.isEmpty || $0.value.localizedCaseInsensitiveContains(searchText) }
            .filter { !hideUnavailable || (canResolve($0.key) ?? true) }
            .sorted { $0.value < $1.value }
            .map { (id: $0.key, name: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Forge Palette", systemImage: "hammer.fill").font(.headline)
                Spacer()
                if placedThisSession > 0 {
                    Text("\(placedThisSession) placed this session")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("New Instance placements armed from this palette in the current editing session, not yet saved. This build has no verified real object-count ceiling to gauge against, so this is a live count, not a budget bar.")
                }
            }
            Text("Pick an object, then click in the viewport to place a brand-new Instance of it. This lists every object ID in the whole game — not every one has geometry data in *this* level's own file (or the shared fallback), so some will place as an amber placeholder cube instead of real geometry; those are marked below. Categories are a best-effort grouping by name text, not verified game data.")
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

            Toggle("Hide objects with no geometry in this level", isOn: $hideUnavailable)
                .font(.caption2)
                .toggleStyle(.checkbox)

            List(filteredEntries, id: \.id) { entry in
                let resolvable = canResolve(entry.id) ?? true
                HStack {
                    Button {
                        onArm(entry.id, entry.name)
                    } label: {
                        HStack {
                            paletteThumbnail(for: entry.id, resolvable: resolvable)
                                .frame(width: 28, height: 28)
                                .onAppear { loadThumbnailIfNeeded(for: entry.id) }
                            Text(entry.name).lineLimit(1).font(.caption)
                                .foregroundStyle(resolvable ? .primary : .secondary)
                            Spacer()
                            Text("#\(entry.id)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        onPin(entry.id, entry.name)
                    } label: {
                        Image(systemName: "pin.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Pin to the numbered hotbar (next open 1-9 slot)")
                }
            }
            .frame(height: 220)
            .listStyle(.bordered)
        }
    }

    /// "Live 3D/2D thumbnail previews before spawning" (roadmap 6.2): a
    /// real offscreen 3D render (`ModelThumbnailRenderer`, same renderer
    /// the Models Hub gallery already uses) per resolvable entry — not a
    /// generic cube glyph standing in for "some model." Entries with no
    /// real geometry keep the amber placeholder glyph, since there's
    /// nothing real to render a thumbnail of.
    @ViewBuilder
    private func paletteThumbnail(for objectID: UInt16, resolvable: Bool) -> some View {
        if let thumbnail = thumbnailCache[objectID] {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if !resolvable || failedThumbnailIDs.contains(objectID) {
            Image(systemName: "cube.transparent")
                .foregroundStyle(.orange)
                .help("No geometry resolves for this object in this level — placing it drops an amber placeholder cube instead of a real model.")
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    /// Same off-main-thread rendering posture as `ModelsHubView.
    /// loadThumbnailIfNeeded` — only skipped if already cached/failed, or
    /// if this entry has no real geometry to render in the first place.
    private func loadThumbnailIfNeeded(for objectID: UInt16) {
        guard thumbnailCache[objectID] == nil, !failedThumbnailIDs.contains(objectID) else { return }
        guard let asset = resolveForThumbnail(objectID) else { return }
        Task.detached(priority: .userInitiated) {
            let image = ModelThumbnailRenderer.render(asset, size: 64)
            await MainActor.run {
                if let image {
                    thumbnailCache[objectID] = image
                } else {
                    failedThumbnailIDs.insert(objectID)
                }
            }
        }
    }
}
