import Foundation
import CTCore
import CTModels

/// Builds the full chunk tree for an `.RM2`/`.SM2` (and their Xbox/Demo
/// variants) file, ported from `Twinsanity/TwinsFile.cs` +
/// `Twinsanity/TwinsSection.cs`.
///
/// The format is a uniform 3-tier chunk structure once you separate it from
/// the original's positional-offset bookkeeping (see `ChunkHeader`'s doc
/// comment for why `indexStartPosition + entry.offset` works identically at
/// every tier, top level included):
///
/// - **Tier 0** (the file itself): dispatches each top-level index entry's ID
///   to either a Tier 1 container section (`Instance`/`Code`/`Graphics` and
///   their Demo/Xbox variants) or a handful of raw leaf record kinds
///   (`ParticleData`, `ColData`, `SceneryData`, `DynamicSceneryData`,
///   `ChunkLinks`) that are *not* chunk-headered at all.
/// - **Tier 1** (a container section): its own index entries each name a
///   *new* Tier 2 collection section (e.g. `Graphics` sub-ID 0 -> a `Texture`
///   collection section), chosen by sub-ID and by whether the enclosing file
///   is PS2/Xbox/Demo.
/// - **Tier 2** (a collection section, e.g. `Texture`, `Model`, `Animation`):
///   every one of its index entries is a leaf record of that section's own
///   kind — sub-ID here is just that record's own ID within the collection,
///   not a further type dispatch.
public enum RM2Parser {
    public enum ParseError: Error, CustomStringConvertible {
        case unsupportedFileType
        public var description: String { "Unsupported or undetected RM2/SM2 file type." }
    }

    public static func parse(data: Data, fileKind: TwinsFileKind, fileName: String) throws -> ChunkNode {
        let root = ChunkNode(recordID: 0, sectionType: .null, displayName: fileName, byteSize: data.count, fileOffset: 0)
        var cursor = BinaryCursor(data: data)
        let header = try ChunkHeaderReader.readHeader(from: &cursor)

        for entry in header.entries {
            let absoluteOffset = header.indexStartPosition + Int(entry.offset)
            guard let node = try? buildTopLevelNode(data: data, entry: entry, absoluteOffset: absoluteOffset, fileKind: fileKind) else {
                continue
            }
            root.children.append(node)
        }
        return root
    }

    // MARK: - Tier 0

    private enum Tier0Kind {
        case section(SectionType)
        case rawLeaf(String)
    }

    private static func tier0Kind(fileKind: TwinsFileKind, subID: UInt32) -> Tier0Kind {
        switch fileKind {
        case .rm2, .rm2Demo, .rmx:
            switch subID {
            case 0...7:
                return .section(fileKind == .rm2Demo ? .instanceDemo : .instance)
            case 8: return .rawLeaf("ParticleData")
            case 9: return .rawLeaf("ColData")
            case 10:
                switch fileKind {
                case .rm2Demo: return .section(.codeDemo)
                case .rmx: return .section(.codeX)
                default: return .section(.code)
                }
            case 11:
                switch fileKind {
                case .rmx: return .section(.graphicsX)
                case .rm2Demo: return .section(.graphicsD)
                default: return .section(.graphics)
                }
            default: return .rawLeaf("Unknown")
            }
        case .sm2, .sm2Demo, .smx:
            switch subID {
            case 6:
                switch fileKind {
                case .smx: return .section(.graphicsX)
                case .sm2Demo: return .section(.graphicsD)
                default: return .section(.graphics)
                }
            case 5: return .rawLeaf("ChunkLinks")
            case 0: return .rawLeaf("SceneryData")
            case 4: return .rawLeaf("DynamicSceneryData")
            default: return .rawLeaf("Unknown")
            }
        }
    }

    private static func buildTopLevelNode(data: Data, entry: ChunkIndexEntry, absoluteOffset: Int, fileKind: TwinsFileKind) throws -> ChunkNode {
        switch tier0Kind(fileKind: fileKind, subID: entry.id) {
        case .section(let sectionType):
            return try buildSectionNode(data: data, sectionType: sectionType, absoluteOffset: absoluteOffset, size: Int(entry.size), recordID: entry.id, level: 1)
        case .rawLeaf(let name):
            return ChunkNode(
                recordID: entry.id, sectionType: .null, displayName: "\(name) #\(entry.id)",
                byteSize: max(0, Int(entry.size)), fileOffset: absoluteOffset,
                payload: .raw(byteCount: max(0, Int(entry.size)))
            )
        }
    }

    // MARK: - Tier 1 (containers) / Tier 2 (collections)

    private static let containerTypes: Set<SectionType> = [.graphics, .graphicsX, .graphicsD, .instance, .instanceDemo, .code, .codeX, .codeDemo]

    private static func tier1ChildType(parent: SectionType, subID: UInt32) -> SectionType? {
        switch parent {
        case .graphics, .graphicsX, .graphicsD:
            switch subID {
            case 0: return parent == .graphicsX ? .textureX : .texture
            case 1: return parent == .graphicsD ? .materialD : .material
            case 2: return parent == .graphicsX ? .modelX : .model
            case 3: return .rigidModel
            case 4: return parent == .graphicsX ? .skinX : .skin
            case 5: return parent == .graphicsX ? .blendSkinX : .blendSkin
            case 6: return .mesh
            case 7: return .lodModel
            case 8: return .skydome
            default: return nil
            }
        case .instance, .instanceDemo:
            switch subID {
            case 0: return parent == .instanceDemo ? .instanceTemplateDemo : .instanceTemplate
            case 1: return .aiPosition
            case 2: return .aiPath
            case 3: return .position
            case 4: return .path
            case 5: return .collisionSurface
            case 6: return parent == .instanceDemo ? .objectInstanceDemo : .objectInstance
            case 7: return .trigger
            case 8: return parent == .instanceDemo ? .cameraDemo : .camera
            default: return nil
            }
        case .code, .codeX, .codeDemo:
            switch subID {
            case 0: return parent == .codeDemo ? .objectDemo : .object
            case 1: return parent == .codeX ? .scriptX : (parent == .codeDemo ? .scriptDemo : .script)
            case 2: return .animation
            case 3: return .ogi
            case 4: return parent == .codeX ? .customAgentX : (parent == .codeDemo ? .customAgentDemo : .customAgent)
            case 6: return parent == .codeX ? .xboxSE : .se
            case 7: return parent == .codeX ? .xboxSEEng : .seEng
            case 8: return parent == .codeX ? .xboxSEFre : .seFre
            case 9: return parent == .codeX ? .xboxSEGer : .seGer
            case 10: return parent == .codeX ? .xboxSESpa : .seSpa
            case 11: return parent == .codeX ? .xboxSEIta : .seIta
            case 12: return parent == .codeX ? .xboxSEJpn : .seJpn
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Builds a node for a chunk-headered section at `absoluteOffset` (either
    /// a Tier 1 container or a Tier 2 collection — both look identical
    /// structurally; only what we *do* with their children differs).
    private static func buildSectionNode(data: Data, sectionType: SectionType, absoluteOffset: Int, size: Int, recordID: UInt32, level: Int) throws -> ChunkNode {
        guard size >= 12, absoluteOffset >= 0, absoluteOffset + size <= data.count else {
            return ChunkNode(recordID: recordID, sectionType: sectionType, displayName: "\(sectionType.rawValue) #\(recordID)", byteSize: max(0, size), fileOffset: absoluteOffset, payload: .raw(byteCount: max(0, size)))
        }
        let sectionData = data.subdata(in: (data.startIndex + absoluteOffset)..<(data.startIndex + absoluteOffset + size))
        var sectionCursor = BinaryCursor(data: sectionData)

        guard let header = try? ChunkHeaderReader.readHeader(from: &sectionCursor) else {
            return ChunkNode(recordID: recordID, sectionType: sectionType, displayName: "\(sectionType.rawValue) #\(recordID)", byteSize: size, fileOffset: absoluteOffset, payload: .raw(byteCount: size))
        }

        let node = ChunkNode(recordID: recordID, sectionType: sectionType, displayName: "\(sectionType.rawValue) #\(recordID)", byteSize: size, fileOffset: absoluteOffset)

        for entry in header.entries {
            let childLocalOffset = header.indexStartPosition + Int(entry.offset)
            let childAbsoluteOffset = absoluteOffset + childLocalOffset
            let childSize = max(0, Int(entry.size))

            if containerTypes.contains(sectionType), let childType = tier1ChildType(parent: sectionType, subID: entry.id) {
                if let childNode = try? buildSectionNode(data: data, sectionType: childType, absoluteOffset: childAbsoluteOffset, size: childSize, recordID: entry.id, level: level + 1) {
                    node.children.append(childNode)
                }
            } else if containerTypes.contains(sectionType) {
                // Sub-ID didn't match a known child type under this container:
                // keep it browsable as a raw leaf rather than dropping it.
                node.children.append(ChunkNode(recordID: entry.id, sectionType: .unknown, displayName: "Unknown #\(entry.id)", byteSize: childSize, fileOffset: childAbsoluteOffset, payload: .raw(byteCount: childSize)))
            } else {
                // Tier 2 collection: every child is a leaf record of `sectionType`.
                node.children.append(buildLeafNode(data: data, sectionType: sectionType, absoluteOffset: childAbsoluteOffset, size: childSize, recordID: entry.id))
            }
        }
        return node
    }

    // MARK: - Tier 2 leaves

    private static func buildLeafNode(data: Data, sectionType: SectionType, absoluteOffset: Int, size: Int, recordID: UInt32) -> ChunkNode {
        let displayName = "\(sectionType.rawValue) #\(recordID)"
        guard absoluteOffset >= 0, size >= 0, absoluteOffset + size <= data.count else {
            return ChunkNode(recordID: recordID, sectionType: sectionType, displayName: displayName, byteSize: max(0, size), fileOffset: absoluteOffset, payload: .raw(byteCount: max(0, size)))
        }
        let leafData = data.subdata(in: (data.startIndex + absoluteOffset)..<(data.startIndex + absoluteOffset + size))
        var cursor = BinaryCursor(data: leafData)
        let payload = decodeLeafPayload(sectionType: sectionType, cursor: &cursor, size: size, recordID: recordID)
        return ChunkNode(recordID: recordID, sectionType: sectionType, displayName: displayName, byteSize: size, fileOffset: absoluteOffset, payload: payload)
    }

    /// Decodes a leaf record's payload where this package understands the
    /// format, and falls back to a raw/undecoded payload everywhere else —
    /// including formats this package deliberately does not attempt (Xbox
    /// `Model`/`Skin` use a different, non-VIF vertex encoding; `BlendSkin`
    /// morph-target blobs; the full `Object`/`Script` component system).
    private static func decodeLeafPayload(sectionType: SectionType, cursor: inout BinaryCursor, size: Int, recordID: UInt32) -> ChunkPayload {
        do {
            switch sectionType {
            case .texture:
                return .texture(try TextureParser.parse(&cursor, recordID: recordID))
            case .textureX:
                return .texture(try TextureXParser.parse(&cursor, recordID: recordID))
            case .model:
                return .mesh(try ModelParser.parse(&cursor, recordID: recordID))
            case .skin:
                return .mesh(try SkinParser.parse(&cursor, recordID: recordID))
            case .rigidModel, .mesh:
                return .rigidModel(try RigidModelParser.parse(&cursor, recordID: recordID))
            case .material:
                return .material(try MaterialParser.parse(&cursor, recordID: recordID))
            case .ogi:
                return .skeleton(try GraphicsInfoParser.parse(&cursor, recordID: recordID))
            case .animation:
                return .animation(try AnimationParser.parse(&cursor, recordID: recordID))
            default:
                return .raw(byteCount: size)
            }
        } catch {
            return .raw(byteCount: size)
        }
    }
}
