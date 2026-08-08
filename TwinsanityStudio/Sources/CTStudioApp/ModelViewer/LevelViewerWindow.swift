import SwiftUI
import CTModels
import UniformTypeIdentifiers

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

    public init(scenery: SceneryAsset, placements: [(worldPosition: SIMD3<Float>, asset: ResolvedModelAsset)], instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)] = []) {
        self.scenery = scenery
        self.placements = placements
        self.instanceMarkers = instanceMarkers
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
struct LevelViewerWindow: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.undoManager) private var undoManager
    let context: LevelViewerContext

    @State private var renderer: LevelViewerRenderer?
    @State private var selectedIndex: Int?
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
            renderer = LevelViewerRenderer(placements: context.placements, instanceMarkers: context.instanceMarkers)
            renderer?.snapToGrid = snapToGrid
            renderer?.gridSize = Float(gridSize)
            renderer?.rotationSnapDegrees = Float(rotationSnapDegrees)
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
                        onGizmoModeChanged: { gizmoMode = renderer.gizmoMode }
                    )
                    // See `ModelViewerWindow`'s matching comment — a
                    // `maxWidth/maxHeight: .infinity`-only frame isn't a
                    // concrete enough size for a `.sheet()`'s first layout
                    // pass to reliably drive the `MTKView` from.
                    .frame(minWidth: 400, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                    Text("Drag to orbit · Scroll to zoom · Drag a handle to \(gizmoMode == .translate ? "move" : gizmoMode == .rotate ? "rotate" : "scale") the selection · W/E/R to switch · F to frame")
                        .font(.caption)
                        .padding(6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
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
                Text(context.scenery.chunkName.isEmpty ? "Level" : context.scenery.chunkName)
                    .font(.title3.bold())

                Form {
                    LabeledContent("Placements in tree", value: "\(context.scenery.placements.count)")
                    LabeledContent("Scenery resolved", value: "\(context.placements.count)")
                    LabeledContent("Instance markers", value: "\(context.instanceMarkers.count)")
                }
                .formStyle(.grouped)

                Text("Scenery objects are drawn at their correct world position, but not yet rotated or scaled to match the level data — only translation is currently applied, and scenery has no write path yet (in-session sandbox only). The amber cubes are Instance records (crate/enemy/platform placements) — their position/rotation is real, live-editable with the gizmo, and \"Save Level Overrides…\" below writes it back to a copy of the file.")
                    .font(.caption2)
                    .foregroundStyle(.orange)

                if !context.instanceMarkers.isEmpty {
                    Button("Save Level Overrides…") { saveLevelOverrides() }
                        .disabled(!workspace.canSaveEdits(for: context.instanceMarkers[0].node))
                    if !workspace.canSaveEdits(for: context.instanceMarkers[0].node) {
                        Text("Editing only saves for a standalone-opened .RM2/.SM2 file — this level's file is archive-packed, which this build doesn't have a write path for yet.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                gizmoControls

                Divider()

                objectList
            }
            .padding(16)
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
    private func saveLevelOverrides() {
        guard let renderer, let firstNode = context.instanceMarkers.first?.node else { return }
        let edits = renderer.pendingLevelOverrides
        guard !edits.isEmpty, let patchedBytes = workspace.patchedFileBytes(applyingPrefixPatches: edits) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(workspace.originalFileName(for: firstNode) ?? "level")_edited.rm2",
            message: "Save the edited copy of this file, with every Instance object's current position/rotation applied. The original file on disk is not modified."
        ) else { return }
        do {
            try patchedBytes.write(to: url)
            workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with \(edits.count) instance override(s). The original file was not modified."
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
}
