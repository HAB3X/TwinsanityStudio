import Foundation
import CTParsers

/// A fully-loaded, already-decoded WoC level, ready to hand to a viewer.
/// Loading happens once, off the main actor (`WOCLevelLoader.load`); this
/// type is the plain data snapshot the UI/renderer read from afterward.
///
/// Deliberately thin: it exposes exactly what's actually decoded
/// (`WOCContainerParser`'s confirmed sections) rather than a speculative
/// "full level" model. `objects` is real, real-world instance placement
/// data (`INST`); there is no per-object mesh geometry here yet -- see
/// `WOCContainerParser`'s doc comment for why (`OBJ0`'s per-entry
/// boundaries are still unsolved as of this type's introduction).
public struct WOCLevelAsset: Identifiable {
    public let id: String
    public let name: String
    public let sourceURL: URL

    public let objectNames: [String]
    public let objects: [WOCObjectInstance]
    /// `OBJ0`'s own leading count -- the number of distinct objects this
    /// level's instances reference. Not necessarily `objects.map(\.objectIndex)`'s
    /// own max+1 in every file (some objects can go unplaced), but it's the
    /// authoritative "how many distinct objects exist" figure.
    public let distinctObjectCount: Int
    public let textureCount: Int
    public let sectionTags: [String]
}

/// One placed object instance (`INST`), reduced to what a viewer needs:
/// world position and which distinct object it is. `WOCContainerParser.Instance`
/// carries the full 4x4 matrix and still-unresolved tail fields; a viewer
/// only needs the translation for a point-cloud/marker render.
public struct WOCObjectInstance: Identifiable {
    public let id: Int
    public let objectIndex: UInt32
    public let worldPosition: SIMD3<Float>
}

public enum WOCLevelLoader {
    public enum LoadError: Error, Equatable {
        case notRNCCompressed
    }

    /// Decompresses and decodes every currently-understood section of a
    /// real `.GSC` file. Synchronous and potentially slow (RNC
    /// decompression of a multi-megabyte file) -- callers should run this
    /// off the main actor.
    public static func load(gscURL: URL, name: String) throws -> WOCLevelAsset {
        let raw = try Data(contentsOf: gscURL)
        let bytes = [UInt8](raw)
        guard RNCDecompressor.isRNCStream(bytes) else { throw LoadError.notRNCCompressed }
        let decoded = try RNCDecompressor.decompress(bytes, verifyCRC: true)
        let file = try WOCContainerParser.parse(decoded)

        var objectNames: [String] = []
        if let ntbl = file.sections.first(where: { $0.tag == "NTBL" }) {
            objectNames = (try? WOCContainerParser.parseNameTable(ntbl.payload))?.names ?? []
        }

        var objects: [WOCObjectInstance] = []
        if let inst = file.sections.first(where: { $0.tag == "INST" }) {
            let instances = (try? WOCContainerParser.parseInstances(inst.payload)) ?? []
            objects = instances.enumerated().map { index, instance in
                WOCObjectInstance(id: index, objectIndex: instance.objectIndex, worldPosition: instance.translation)
            }
        }

        var distinctObjectCount = 0
        if let obj0 = file.sections.first(where: { $0.tag == "OBJ0" }) {
            distinctObjectCount = (try? WOCContainerParser.leadingCount(obj0.payload)) ?? 0
        }

        var textureCount = 0
        if let tst0 = file.sections.first(where: { $0.tag == "TST0" }) {
            textureCount = WOCContainerParser.scanTextureEntries(tst0.payload).count
        }

        return WOCLevelAsset(
            id: gscURL.path,
            name: name,
            sourceURL: gscURL,
            objectNames: objectNames,
            objects: objects,
            distinctObjectCount: distinctObjectCount,
            textureCount: textureCount,
            sectionTags: file.sections.map(\.tag)
        )
    }
}
