import Foundation
import CTParsers
import CTModels

/// A fully-loaded, already-decoded WoC level, ready to hand to a viewer.
/// Loading happens once, off the main actor (`WOCLevelLoader.load`); this
/// type is the plain data snapshot the UI/renderer read from afterward.
///
/// Deliberately thin: it exposes exactly what's actually decoded across
/// this level's `.GSC` (the RNC-compressed container) and its sibling
/// loose files (`.AI`/`.GRA`/`.PAD`/`.ANM`/`.TER`, all uncompressed, same
/// folder, same base filename) rather than a speculative "full level"
/// model. `objects` is real placement data (`INST`); there is no
/// per-object mesh geometry here yet -- see `WOCContainerParser`'s doc
/// comment for why (`OBJ0`'s per-entry boundaries are still unsolved as
/// of this type's introduction). Several categories (sound, cameras,
/// collision, skeletons) aren't represented here at all because they
/// haven't been reverse-engineered yet -- there is no placeholder/fake
/// data standing in for them.
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
    public let textures: [WOCDecodedTexture]
    public let sectionTags: [String]
    /// Real per-object mesh geometry, indexed exactly like `OBJ0` itself
    /// (`objects[i].objectIndex` looks up here) -- see `WOCMeshDecoder`'s
    /// doc comment for the confirmed byte layout this is built from
    /// (`OBJ0`'s "arc" vertex batches, grouped into entries). Empty when
    /// this file's chunk walk hit the known marker-reuse bug (`CASTLE_C.
    /// GSC`/`HUB.GSC`-shaped files -- see `WOCContainerParser.
    /// groupOBJ0ChunksIntoEntries`) and grouping was refused rather than
    /// guessed at; the viewer falls back to a position marker in that
    /// case, same as before this existed. Positions only, no rotation
    /// applied yet -- `INST`'s own rotation matrix is real, decoded data
    /// (`WOCContainerParser.Instance.matrix`) but this viewer doesn't
    /// apply it yet, matching the point-cloud renderer's own existing
    /// position-only behavior rather than introducing a new, unverified
    /// claim about this format's matrix convention.
    public let objectMeshes: [MeshAsset]

    /// From the sibling `.AI` file, if present: real enemy/AI entity
    /// spawns with patrol waypoint paths. Fully decoded (see
    /// `WOCAIParser`).
    public let entities: [WOCAIParser.Entity]
    /// From the sibling `.GRA` file, if present: real foliage/grass
    /// scatter placements. Fully decoded (see `WOCGrassParser`).
    public let foliage: [WOCGrassParser.Placement]
    /// From the sibling `.ANM` file, if present AND it fits the confirmed
    /// simple-object-animation template -- real skeletal-animation files
    /// (a different, undecoded format) leave this empty rather than
    /// showing garbage; see `animationFileExistsButUnparsed`.
    public let animations: [WOCAnimationParser.Entry]
    /// `true` when a sibling `.ANM` file exists but didn't fit the
    /// confirmed simple-object-animation template (real skeletal files
    /// like `TOONARMY.ANM`) -- surfaced so the UI can say "present, not
    /// yet decoded" instead of just "none".
    public let animationFileExistsButUnparsed: Bool
    /// From the sibling `.PAD` file, if present: real record count and
    /// framing, but record *semantics* are unresolved (see
    /// `WOCPadParser`) -- exposed as a raw count, not interpreted data.
    public let pathRecordCount: Int?
    /// From the sibling `.TER` file, if present: confirmed outer framing
    /// only. The bulk of real terrain/collision geometry (the "main
    /// block") is not decoded -- `terrainMainBlockByteCount` says how
    /// much real data is there without pretending to show its content.
    public let terrainMainBlockByteCount: Int?
    public let terrainTailRecordCount: Int?

    public var textureCount: Int { textures.count }
}

/// One real, decoded texture (see `WOCTextureDecoder`) -- RGBA8888, raw
/// bytes rather than a platform image type, so this model stays usable
/// off the main actor; `WOCViewerWindow` builds the actual `CGImage` at
/// display time.
public struct WOCDecodedTexture: Identifiable {
    public let id: Int
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
    /// `true` for indexed (paletted) textures whose CLUT was found and
    /// applied; `false` for direct-color textures (no palette needed) or
    /// indexed textures whose CLUT search failed (`rgba` is empty in that
    /// failure case, not fabricated placeholder pixels).
    public let usedPalette: Bool
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
    /// real `.GSC` file, plus every sibling loose file this codebase
    /// currently understands (looked up by swapping the extension on the
    /// same URL -- these are real, separate files on disk, not embedded
    /// in the `.GSC`). Synchronous and potentially slow (RNC
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
        var objectMeshes: [MeshAsset] = []
        if let obj0 = file.sections.first(where: { $0.tag == "OBJ0" }) {
            distinctObjectCount = (try? WOCContainerParser.leadingCount(obj0.payload)) ?? 0
            objectMeshes = WOCMeshDecoder.buildEntryMeshes(objectPayload: obj0.payload) ?? []
        }

        var textures: [WOCDecodedTexture] = []
        if let tst0 = file.sections.first(where: { $0.tag == "TST0" }) {
            let entries = WOCContainerParser.scanTextureEntries(tst0.payload)
            for (index, entry) in entries.enumerated() {
                let texel = tst0.payload.subdata(in: entry.texelDataRange)
                if entry.bytesPerPixel == 4 {
                    let rgba = WOCTextureDecoder.decodeDirectColor(texel, width: entry.width, height: entry.height)
                    textures.append(WOCDecodedTexture(id: index, width: entry.width, height: entry.height, rgba: rgba, usedPalette: false))
                } else if let palette = WOCTextureDecoder.findPalette(precedingTrailerOffset: entry.trailerOffset, in: tst0.payload) {
                    let rgba = WOCTextureDecoder.decodeIndexed(texel, palette: palette, width: entry.width, height: entry.height)
                    textures.append(WOCDecodedTexture(id: index, width: entry.width, height: entry.height, rgba: rgba, usedPalette: true))
                } else {
                    // Real, honest failure case: an indexed texture whose
                    // CLUT couldn't be located -- no fabricated pixels.
                    textures.append(WOCDecodedTexture(id: index, width: entry.width, height: entry.height, rgba: [], usedPalette: false))
                }
            }
        }

        let baseURL = gscURL.deletingPathExtension()

        var entities: [WOCAIParser.Entity] = []
        if let aiData = try? Data(contentsOf: baseURL.appendingPathExtension("AI")) {
            entities = (try? WOCAIParser.parse(aiData)) ?? []
        }

        var foliage: [WOCGrassParser.Placement] = []
        if let graData = try? Data(contentsOf: baseURL.appendingPathExtension("GRA")) {
            foliage = (try? WOCGrassParser.parse(graData)) ?? []
        }

        var animations: [WOCAnimationParser.Entry] = []
        var animationFileExistsButUnparsed = false
        if let anmData = try? Data(contentsOf: baseURL.appendingPathExtension("ANM")) {
            if let parsed = try? WOCAnimationParser.parse(anmData) {
                animations = parsed
            } else {
                animationFileExistsButUnparsed = true
            }
        }

        var pathRecordCount: Int?
        if let padData = try? Data(contentsOf: baseURL.appendingPathExtension("PAD")) {
            pathRecordCount = (try? WOCPadParser.parse(padData))?.records.count
        }

        var terrainMainBlockByteCount: Int?
        var terrainTailRecordCount: Int?
        if let terData = try? Data(contentsOf: baseURL.appendingPathExtension("TER")) {
            if let parsed = try? WOCTerrainParser.parse(terData) {
                terrainMainBlockByteCount = parsed.mainBlock.count
                terrainTailRecordCount = parsed.tailRecords.count
            }
        }

        return WOCLevelAsset(
            id: gscURL.path,
            name: name,
            sourceURL: gscURL,
            objectNames: objectNames,
            objects: objects,
            distinctObjectCount: distinctObjectCount,
            textures: textures,
            sectionTags: file.sections.map(\.tag),
            objectMeshes: objectMeshes,
            entities: entities,
            foliage: foliage,
            animations: animations,
            animationFileExistsButUnparsed: animationFileExistsButUnparsed,
            pathRecordCount: pathRecordCount,
            terrainMainBlockByteCount: terrainMainBlockByteCount,
            terrainTailRecordCount: terrainTailRecordCount
        )
    }
}
