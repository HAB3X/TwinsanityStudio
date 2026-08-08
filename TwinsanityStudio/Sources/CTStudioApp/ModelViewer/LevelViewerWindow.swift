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

    public init(scenery: SceneryAsset, placements: [(worldPosition: SIMD3<Float>, asset: ResolvedModelAsset)]) {
        self.scenery = scenery
        self.placements = placements
    }
}

/// "Scenery/Level Assembly" + "Forge-Style Editor Mode" (blueprint 6.1/6.2):
/// a multi-object Metal viewport drawing every resolved scenery placement,
/// with a translate gizmo on the selected object, coordinate nudge fields,
/// snap-to-grid, and a drag target for adding new objects from the Models
/// Hub. None of this writes back to the level file — `SceneryData` has no
/// write path in this build (see `WorkspaceViewModel.patchedFileBytes`'s
/// doc comment for the one record type that does) — everything here is an
/// in-session editing sandbox, not a save/export path yet.
struct LevelViewerWindow: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.undoManager) private var undoManager
    let context: LevelViewerContext

    @State private var renderer: LevelViewerRenderer?
    @State private var selectedIndex: Int?
    @State private var positionX: String = ""
    @State private var positionY: String = ""
    @State private var positionZ: String = ""
    @State private var snapToGrid = true
    @State private var gridSize: Double = 1.0
    @State private var isDropTargeted = false
    /// Position captured at the start of a gizmo drag or a nudge-field
    /// edit, so ⌘Z has something to restore to — see `registerUndo`.
    @State private var positionBeforeEdit: SIMD3<Float>?

    var body: some View {
        HStack(spacing: 0) {
            viewportArea
            Divider()
            sidebar
                .frame(width: 320)
        }
        .frame(minWidth: 960, minHeight: 620)
        .onAppear {
            renderer = LevelViewerRenderer(placements: context.placements)
            renderer?.snapToGrid = snapToGrid
            renderer?.gridSize = Float(gridSize)
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
        refreshPositionFields()
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
                            registerUndo(from: positionBeforeEdit)
                            refreshPositionFields()
                        },
                        onGizmoDragStarted: { positionBeforeEdit = renderer.selectedPosition }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text("Drag to orbit · Scroll to zoom · Drag an axis arrow to move the selected object · F to frame selection")
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
                    refreshPositionFields()
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
                    LabeledContent("Resolved & drawn", value: "\(renderer?.objectCount ?? context.placements.count)")
                }
                .formStyle(.grouped)

                Text("Objects are drawn at their correct world position, but not yet rotated or scaled to match the level data — only translation is currently applied. Shape/orientation of individual pieces may look off even though placement roughly matches the level layout. Nothing here writes back to the level file yet — this is an in-session sandbox (see the Models Hub for drag-and-drop).")
                    .font(.caption2)
                    .foregroundStyle(.orange)

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

            Toggle("Snap to Grid", isOn: $snapToGrid)
                .toggleStyle(.checkbox)
                .help("When on, dragging a gizmo arrow rounds the moved axis to the nearest grid step instead of moving freely.")
                .onChange(of: snapToGrid) { _, newValue in renderer?.snapToGrid = newValue }

            HStack {
                Text("Grid Size")
                Stepper(value: $gridSize, in: 0.1...100, step: 0.5) {
                    Text(String(format: "%.1f", gridSize))
                }
                .help("World units between grid snap points.")
                .onChange(of: gridSize) { _, newValue in renderer?.gridSize = Float(newValue) }
            }

            if selectedIndex != nil {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("X"); positionField($positionX)
                    }
                    GridRow {
                        Text("Y"); positionField($positionY)
                    }
                    GridRow {
                        Text("Z"); positionField($positionZ)
                    }
                }
                Button("Apply Position") { applyPositionFields() }
                    .help("Move the selected object to this exact world position. ⌘Z undoes it, same as a gizmo drag.")
            } else {
                Text("Select an object below (or drag one from the Models Hub into the viewport) to move it with the gizmo or these fields.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func positionField(_ text: Binding<String>) -> some View {
        TextField("", text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
            .onSubmit { applyPositionFields() }
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
        refreshPositionFields()
    }

    private func refreshPositionFields() {
        guard let position = renderer?.selectedPosition else { return }
        positionX = String(format: "%.2f", position.x)
        positionY = String(format: "%.2f", position.y)
        positionZ = String(format: "%.2f", position.z)
    }

    private func applyPositionFields() {
        guard let x = Float(positionX), let y = Float(positionY), let z = Float(positionZ) else { return }
        let before = renderer?.selectedPosition
        renderer?.setSelectedPosition(to: SIMD3(x, y, z))
        registerUndo(from: before)
    }

    /// Registers one ⌘Z step moving the selected object from
    /// `previousPosition` back to where it was, and (via the recursive
    /// helper below) a matching ⌘⇧Z redo back to where it ended up —
    /// deliberately built entirely from stable references (`undoManager`,
    /// `renderer`, the object's index, plain `SIMD3<Float>` values), not by
    /// capturing `self`/`@State` inside the closure `UndoManager` holds
    /// onto: this View struct gets recreated on every SwiftUI re-render,
    /// and a stale captured copy of it would be the wrong kind of thing for
    /// a long-lived undo stack to hold a reference to.
    private func registerUndo(from previousPosition: SIMD3<Float>?) {
        guard let undoManager, let previousPosition, let index = selectedIndex, let renderer,
              let newPosition = renderer.selectedPosition, newPosition != previousPosition
        else { return }
        undoManager.setActionName("Move Object")
        Self.registerPositionUndo(undoManager: undoManager, renderer: renderer, index: index, restoreTo: previousPosition, thenRedoTo: newPosition)
    }

    private static func registerPositionUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, index: Int, restoreTo: SIMD3<Float>, thenRedoTo: SIMD3<Float>) {
        undoManager.registerUndo(withTarget: renderer) { target in
            target.select(index: index)
            target.setSelectedPosition(to: restoreTo)
            registerPositionUndo(undoManager: undoManager, renderer: target, index: index, restoreTo: thenRedoTo, thenRedoTo: restoreTo)
        }
    }
}
