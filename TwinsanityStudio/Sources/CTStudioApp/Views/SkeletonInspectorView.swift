import SwiftUI
import CTModels

struct SkeletonInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let skeleton: SkeletonAsset

    private var tree: SkeletonTreeNode? { skeleton.buildTree() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                LabeledContent("Joints", value: "\(skeleton.joints.count)")
                LabeledContent("Exit Points", value: "\(skeleton.exitPoints.count)")
                LabeledContent("Skin ID", value: "\(skeleton.skinID)")
                LabeledContent("Blend Skin ID", value: "\(skeleton.blendSkinID)")
                LabeledContent("Model Links", value: "\(skeleton.modelLinks.count)")
            }
            .formStyle(.grouped)

            Button {
                workspace.openModelViewer(for: node)
            } label: {
                Label("Open in Model Viewer", systemImage: "cube.fill")
            }

            Text("Joint Hierarchy")
                .font(.headline)
            if let tree {
                List {
                    OutlineGroup(tree, children: \.childrenIfAny) { node in
                        HStack {
                            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.orange)
                            Text("Joint \(node.joint.jointIndex)")
                            Spacer()
                            Text("parent \(node.joint.parentJointIndex)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 320)
            } else {
                Text("No joints in this record.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension SkeletonTreeNode {
    var childrenIfAny: [SkeletonTreeNode]? { children.isEmpty ? nil : children }
}
