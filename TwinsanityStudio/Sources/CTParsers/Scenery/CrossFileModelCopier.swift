import Foundation
import CTCore
import CTModels

/// Copies a `RigidModel` (mesh + its materials + their textures) from one
/// file's `Graphics` section into another's — the missing piece for
/// "place a scenery object sourced from a different level," since a
/// `SceneryModelPlacement.modelID` is a file-local number (level A's
/// model #12 means nothing in level B's own `GraphicsAssetIndex`).
///
/// Every copied record's real, raw on-disk bytes are used verbatim (never
/// re-encoded through a from-scratch writer this codebase doesn't have for
/// `RigidModel`/`Material`/`Texture`/`Model`) — always assigned a **fresh**
/// ID in the destination (never reusing the source's own number, even if
/// that number happens to be free in the destination too), with the small
/// number of *internal* cross-references those formats carry
/// (`RigidModel.materialIDs`/`meshID`, `TwinsShader.textureId` inside each
/// copied `Material`) patched in place to point at the fresh copies —
/// verified against the reference's own `RigidModel.FillPackage`/
/// `Material.FillPackage` (`Twinsanity/Items/Graphics/RigidModel.cs`/
/// `Material.cs`), which walk the exact same dependency closure for
/// CrateModLoader's mod-packaging, though that code reuses the *same* ID
/// across files rather than remapping — always assigning fresh IDs here
/// instead avoids that approach's real collision risk (two different
/// levels' assets sharing a small sequential ID number is common, not
/// rare) at the cost of never de-duplicating a re-placed object across
/// multiple placements.
///
/// One deliberate simplification: if the source placement was `isSpecial`
/// (reached its `RigidModel` through a `LodModel` indirection —
/// `SceneryModelPlacement.isSpecial`'s own doc comment), this resolves
/// straight to the concrete `RigidModel` those LOD levels bottom out at
/// and creates the new placement as **non-special**, pointing at it
/// directly — a real, working object, just always at full detail rather
/// than LOD-switching. Copying a `LodModel` wrapper too is real, separate
/// work this doesn't attempt.
public enum CrossFileModelCopier {
    public struct CopyResult: Sendable {
        public var destinationBytes: Data
        /// The fresh `RigidModel` ID in the *destination* file — use this
        /// (with `isSpecial: false`) for the new `SceneryModelPlacement`.
        public var rigidModelID: UInt32
    }

    public enum CopyError: Error, LocalizedError {
        case missingGraphicsCollection(SectionType, file: String)
        case recordNotFound(SectionType, UInt32)
        case lodModelDidNotResolve(UInt32)
        case insertionFailed

        public var errorDescription: String? {
            switch self {
            case .missingGraphicsCollection(let type, let file):
                return "The \(file) file has no \(type) collection this build recognizes."
            case .recordNotFound(let type, let id):
                return "Couldn't find \(type) #\(id) — the source file may be missing real data this placement depends on."
            case .lodModelDidNotResolve(let id):
                return "LodModel #\(id)'s alternate RigidModel IDs didn't resolve to any real RigidModel in the source file."
            case .insertionFailed:
                return "Internal error: couldn't safely insert the copied records into the destination file's structure."
            }
        }
    }

    /// Copies everything needed to render `modelID` (a real
    /// `SceneryModelPlacement.modelID`/`isSpecial` pair from `sourceFileRoot`)
    /// into `destinationFileRoot`'s own `Graphics` collections. Neither
    /// input file's bytes are modified in place — `destinationBytes` is
    /// the destination file's *current* bytes (already-open working copy,
    /// same convention as every other insertion in this app), and the
    /// result is a brand-new complete replacement for it.
    public static func copyingRigidModelChain(
        modelID: UInt32,
        isSpecial: Bool,
        sourceFileRoot: ChunkNode,
        sourceBytes: Data,
        destinationFileRoot: ChunkNode,
        destinationBytes: Data
    ) throws -> CopyResult {
        guard let sourceRigidModels = graphicsCollection(.rigidModel, in: sourceFileRoot) else {
            throw CopyError.missingGraphicsCollection(.rigidModel, file: "source")
        }
        guard let sourceMaterials = graphicsCollection(.material, in: sourceFileRoot) else {
            throw CopyError.missingGraphicsCollection(.material, file: "source")
        }
        guard let sourceTextures = graphicsCollection(.texture, in: sourceFileRoot) else {
            throw CopyError.missingGraphicsCollection(.texture, file: "source")
        }
        guard let sourceModels = graphicsCollection(.model, in: sourceFileRoot) else {
            throw CopyError.missingGraphicsCollection(.model, file: "source")
        }
        guard let destRigidModels = graphicsCollection(.rigidModel, in: destinationFileRoot) else {
            throw CopyError.missingGraphicsCollection(.rigidModel, file: "destination")
        }
        guard let destMaterials = graphicsCollection(.material, in: destinationFileRoot) else {
            throw CopyError.missingGraphicsCollection(.material, file: "destination")
        }
        guard let destTextures = graphicsCollection(.texture, in: destinationFileRoot) else {
            throw CopyError.missingGraphicsCollection(.texture, file: "destination")
        }
        guard let destModels = graphicsCollection(.model, in: destinationFileRoot) else {
            throw CopyError.missingGraphicsCollection(.model, file: "destination")
        }

        // Resolve `modelID` down to a real, concrete RigidModel ID —
        // `AssetResolver.resolveModelID`'s own logic (isSpecial -> LodModel
        // indirection, first lodModelIDs entry that actually exists),
        // reimplemented locally since that function is decode-oriented
        // (returns a `ResolvedModelAsset`) where this needs the real
        // record *ID* to locate its raw bytes.
        var realRigidModelID = modelID
        if isSpecial {
            guard let lodNode = graphicsCollection(.lodModel, in: sourceFileRoot)?.children.first(where: { $0.recordID == modelID }),
                  case .lodModel(let lodInfo)? = lodNode.payload
            else { throw CopyError.recordNotFound(.lodModel, modelID) }
            guard let resolved = lodInfo.lodModelIDs.first(where: { candidate in sourceRigidModels.children.contains { $0.recordID == candidate } }) else {
                throw CopyError.lodModelDidNotResolve(modelID)
            }
            realRigidModelID = resolved
        }

        guard let rigidModelNode = sourceRigidModels.children.first(where: { $0.recordID == realRigidModelID }),
              case .rigidModel(let rigidModelInfo)? = rigidModelNode.payload
        else { throw CopyError.recordNotFound(.rigidModel, realRigidModelID) }

        var nextTextureID = (destTextures.children.map(\.recordID).max() ?? 0) + 1
        var nextMaterialID = (destMaterials.children.map(\.recordID).max() ?? 0) + 1
        let newRigidModelID = (destRigidModels.children.map(\.recordID).max() ?? 0) + 1
        let newMeshID = (destModels.children.map(\.recordID).max() ?? 0) + 1

        guard let meshSourceNode = sourceModels.children.first(where: { $0.recordID == rigidModelInfo.meshID }) else {
            throw CopyError.recordNotFound(.model, rigidModelInfo.meshID)
        }
        let modelInserts: [(id: UInt32, encoded: Data)] = [(newMeshID, rawBytes(of: meshSourceNode, in: sourceBytes))]

        var textureInserts: [(id: UInt32, encoded: Data)] = []
        var materialInserts: [(id: UInt32, encoded: Data)] = []
        var materialIDRemap: [UInt32: UInt32] = [:]
        var textureIDRemap: [UInt32: UInt32] = [:]

        for materialID in rigidModelInfo.materialIDs where materialIDRemap[materialID] == nil {
            guard let materialNode = sourceMaterials.children.first(where: { $0.recordID == materialID }) else {
                throw CopyError.recordNotFound(.material, materialID)
            }
            var materialBytes = rawBytes(of: materialNode, in: sourceBytes)
            let shaderOffsets = try shaderTextureIDOffsets(in: materialBytes)
            for shader in shaderOffsets {
                let newTextureID: UInt32
                if let already = textureIDRemap[shader.textureID] {
                    newTextureID = already
                } else {
                    guard let textureNode = sourceTextures.children.first(where: { $0.recordID == shader.textureID }) else {
                        throw CopyError.recordNotFound(.texture, shader.textureID)
                    }
                    newTextureID = nextTextureID
                    nextTextureID += 1
                    textureInserts.append((newTextureID, rawBytes(of: textureNode, in: sourceBytes)))
                    textureIDRemap[shader.textureID] = newTextureID
                }
                writeUInt32LE(newTextureID, at: shader.offset, in: &materialBytes)
            }
            let newMaterialID = nextMaterialID
            nextMaterialID += 1
            materialInserts.append((newMaterialID, materialBytes))
            materialIDRemap[materialID] = newMaterialID
        }

        var rigidModelBytes = rawBytes(of: rigidModelNode, in: sourceBytes)
        // `RigidModel`'s own fixed layout (`RigidModel.cs`'s `Save`):
        // header(4) + count(4) + materialIDs[count*4] + meshID(4) — every
        // offset is derivable from the count field itself, no separately-
        // tracked offsets needed (unlike `Material`'s variable-length
        // shader blocks above).
        for (index, materialID) in rigidModelInfo.materialIDs.enumerated() {
            guard let remapped = materialIDRemap[materialID] else { continue }
            writeUInt32LE(remapped, at: 8 + index * 4, in: &rigidModelBytes)
        }
        writeUInt32LE(newMeshID, at: 8 + rigidModelInfo.materialIDs.count * 4, in: &rigidModelBytes)

        let targets: [(section: ChunkNode, insert: [(id: UInt32, encoded: Data)], removeIDs: [UInt32])] = [
            (destTextures, textureInserts, []),
            (destMaterials, materialInserts, []),
            (destModels, modelInserts, []),
            (destRigidModels, [(newRigidModelID, rigidModelBytes)], []),
        ].filter { !$0.insert.isEmpty }

        guard let result = ChunkSectionInserter.applyingRecordChanges(intoSections: targets, fileRoot: destinationFileRoot, originalFileBytes: destinationBytes) else {
            throw CopyError.insertionFailed
        }
        return CopyResult(destinationBytes: result, rigidModelID: newRigidModelID)
    }

    // MARK: - Helpers

    private static func rawBytes(of node: ChunkNode, in bytes: Data) -> Data {
        bytes.subdata(in: (bytes.startIndex + node.fileOffset)..<(bytes.startIndex + node.fileOffset + node.byteSize))
    }

    /// The `.graphics`/`.graphicsX`/`.graphicsD` container's child whose
    /// own `sectionType` is `type` — the collection node
    /// `ChunkSectionInserter` targets to add a new record.
    private static func graphicsCollection(_ type: SectionType, in fileRoot: ChunkNode) -> ChunkNode? {
        let containerTypes: Set<SectionType> = [.graphics, .graphicsX, .graphicsD]
        func walk(_ node: ChunkNode) -> ChunkNode? {
            if containerTypes.contains(node.sectionType) {
                return node.children.first { $0.sectionType == type }
            }
            for child in node.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// Walks a real, already-valid `Material` record's own bytes exactly
    /// like `MaterialParser.readShader` does (shaderType-keyed variable
    /// param block, then the fixed render-state fields), but records each
    /// shader's `textureId` absolute byte offset instead of building a
    /// `TwinsShaderInfo` — this is the one field inside a raw-copied
    /// `Material` that must be patched to point at the freshly-copied
    /// texture instead of the source file's own texture ID.
    private static func shaderTextureIDOffsets(in materialBytes: Data) throws -> [(offset: Int, textureID: UInt32)] {
        var cursor = BinaryCursor(data: materialBytes)
        _ = try cursor.readUInt64() // Header
        _ = try cursor.readInt32()  // Unknown
        let nameLen = Int(try cursor.readInt32())
        _ = try cursor.readBytes(nameLen)
        let shaderCount = try cursor.readInt32()

        var results: [(offset: Int, textureID: UInt32)] = []
        for _ in 0..<max(0, shaderCount) {
            let shaderType = try cursor.readUInt32()
            switch shaderType {
            case 23:
                _ = try cursor.readUInt32()
                _ = try cursor.readFloat32()
                _ = try cursor.readFloat32()
            case 26:
                _ = try cursor.readUInt32()
                for _ in 0..<4 { _ = try cursor.readFloat32() }
            case 16, 17:
                _ = try cursor.readFloat32()
            default:
                break
            }
            _ = try cursor.readBytes(17)
            _ = try cursor.readBool()
            _ = try cursor.readBytes(6)
            _ = try cursor.readBytes(3)
            _ = try cursor.readUInt8()
            _ = try cursor.readBytes(2)
            _ = try cursor.readUInt16()
            _ = try cursor.readUInt16()
            _ = try cursor.readBytes(48)

            let textureIDOffset = cursor.position
            let textureID = try cursor.readUInt32()
            _ = try cursor.readUInt32() // trailing repeated ShaderType
            results.append((textureIDOffset, textureID))
        }
        return results
    }

    private static func writeUInt32LE(_ value: UInt32, at offset: Int, in data: inout Data) {
        let base = data.startIndex + offset
        data[base] = UInt8(value & 0xFF)
        data[base + 1] = UInt8((value >> 8) & 0xFF)
        data[base + 2] = UInt8((value >> 16) & 0xFF)
        data[base + 3] = UInt8((value >> 24) & 0xFF)
    }
}
