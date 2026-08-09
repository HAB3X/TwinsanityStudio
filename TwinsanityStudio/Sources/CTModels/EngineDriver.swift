import Foundation
import CTCore

/// Identifies one Traveller's Tales-era engine variant this build knows how to
/// read, and what it's capable of for that variant. This is the seam a
/// "Pluggable Engine Driver System" hangs off of — but a seam is only useful
/// once something concrete is plugged into it, and today that's exactly one
/// thing: `TwinsanityEngineDriver`, backed by the real, source-grounded
/// `RM2Parser`/`BDArchiveParser`/etc. in `CTParsers`.
///
/// Deliberately *not* shipped with here: drivers for Nu2-engine titles,
/// Haven: Call of the King, the early LEGO games, or Crash Nitro Kart. Their
/// chunk layouts, record formats, and endianness conventions would all have
/// to be reverse-engineered from scratch — this repository has no verified
/// reference source for any of them (compare `twinsanity-editor-master`,
/// which *is* a verified reference for Twinsanity itself, and is what every
/// parser in `CTParsers` is grounded in). A driver stubbed out against
/// guessed offsets wouldn't be "multi-engine support" — it would silently
/// misparse or crash on real files while claiming to work. When a real
/// reference (community documentation, a decompiled binary, another OSS
/// tool) surfaces for one of those engines, it gets its own
/// `EngineDriver` conformance next to this one; until then, this stays a
/// single-entry registry on purpose.
public protocol EngineDriver: Sendable {
    /// Stable identifier, e.g. `"twinsanity"` — used for display and for
    /// any future per-driver settings/caching, never parsed from file data.
    var id: String { get }
    var displayName: String { get }
    /// Console platforms this driver has verified parsing for.
    var supportedPlatforms: [ConsolePlatform] { get }
    /// File extensions (uppercased, no dot) this driver's archive/level
    /// parsers recognize, e.g. `["RM2", "SM2", "RMX", "SMX"]`.
    var recognizedExtensions: Set<String> { get }
    /// The byte order this driver's structural fields are read as. See
    /// `Endianness`'s doc comment: Twinsanity's own PS2/Xbox split is a
    /// vertex/pixel-layout difference, not a byte-order one, but a future
    /// GameCube-era driver genuinely could differ here.
    var structuralEndianness: Endianness { get }
    /// What actually happens when a file this driver recognizes gets
    /// opened. "Pluggable Engine Driver System" (roadmap 5.3): the seam
    /// this describes is real and used — `WorkspaceViewModel.open(url:)`
    /// branches on this instead of hardcoding "is this the Twinsanity
    /// driver specifically." It's still a small seam, deliberately: making
    /// every parser/exporter/viewer route *through* a driver object rather
    /// than calling `RM2Parser`/`BDArchiveParser`/etc. directly would touch
    /// most of this package for no verified benefit today (there's exactly
    /// one driver whose files load into the main tree at all), and would
    /// risk silently breaking the one real, working ingestion path this
    /// build has. This capability flag is the part of "pluggable" that's
    /// both real and safe to land now; a deeper parser-level dispatch stays
    /// future work, not something to fake by routing calls through an
    /// object that still only ever forwards to the same one concrete
    /// parser underneath.
    var ingestionCapability: EngineDriverIngestionCapability { get }
}

/// What `WorkspaceViewModel.open(url:)` should do with a file a given
/// `EngineDriver` recognizes.
public enum EngineDriverIngestionCapability: Sendable {
    /// This driver's files parse directly into the main sidebar/workspace
    /// tree (`WorkspaceAutoDetector` + `RM2Parser`/`BDArchiveParser`).
    case mainWorkspaceTree
    /// This driver's files are real and loadable, but only through their
    /// own dedicated panel — not because of an arbitrary restriction, but
    /// because they aren't chunk-headered `ChunkNode` data at all (see
    /// `WrathOfCortexEngineDriver`'s own doc comment), so there's no
    /// sidebar tree shape for them to become part of.
    case standaloneOnly(loadHint: String)
}

/// The one real driver this build has: everything under `CTParsers` today
/// (`BDArchiveParser`, `RM2Parser`, `TextureParser`/`TextureXParser`,
/// `ModelParser`/`SkinParser`, `GraphicsInfoParser`/`AnimationParser`, ...)
/// *is* this driver's implementation — this type doesn't re-wrap or dispatch
/// through those parsers (that would just be indirection with nothing behind
/// it yet), it names them as a unit so `EngineDriverRegistry` has something
/// non-empty to register.
public struct TwinsanityEngineDriver: EngineDriver {
    public let id = "twinsanity"
    public let displayName = "Crash Twinsanity"
    public let supportedPlatforms: [ConsolePlatform] = [.ps2, .xbox]
    public let recognizedExtensions: Set<String> = ["RM2", "SM2", "RMX", "SMX"]
    public let structuralEndianness: Endianness = .little
    public let ingestionCapability: EngineDriverIngestionCapability = .mainWorkspaceTree

    public init() {}
}

/// "Modular TT Engine Cross-Compatibility & Chunk Stitcher" (roadmap 5.3):
/// the second real driver — *Crash Twinsanity: The Wrath of Cortex*'s
/// `.CRT` (crate positions) and `.WMP` (Wumpa fruit positions) files,
/// backed by `WrathOfCortexParser`, itself ported field-for-field from
/// CrateModLoader's real, working `TWOC_File_CRT.cs`/`TWOC_File_WMP.cs` —
/// a genuine, verified reference source, meeting the bar `EngineDriver`'s
/// own doc comment sets for adding a new entry here (not a guess at
/// offsets). Scoped honestly: `supportedPlatforms` is PS2 only — the
/// reference tool's own `LoadGC`/`BinaryReader2` path for the GameCube
/// release uses a different (likely byte-swapped) reader this build
/// doesn't port, and `WrathOfCortexParser` was never checked against a
/// real Wrath of Cortex disc image the way every Twinsanity parser in this
/// build was (no such disc is available in this environment) — see
/// `WOCCrateFile`'s own doc comment for the same caveat.
public struct WrathOfCortexEngineDriver: EngineDriver {
    public let id = "wrath-of-cortex"
    public let displayName = "Crash Twinsanity: The Wrath of Cortex"
    public let supportedPlatforms: [ConsolePlatform] = [.ps2]
    public let recognizedExtensions: Set<String> = ["CRT", "WMP"]
    public let structuralEndianness: Endianness = .little
    public let ingestionCapability: EngineDriverIngestionCapability = .standaloneOnly(
        loadHint: "open a Chunk Viewer and use its \"Cross-Engine Data\" panel's \"Load Wrath of Cortex File…\" button instead."
    )

    public init() {}
}

/// Every engine driver this build ships. See `EngineDriver`'s doc comment
/// for why an entry only ever gets added here once a real, verified format
/// spec exists — never a guess dressed up as support.
public enum EngineDriverRegistry {
    public static let all: [any EngineDriver] = [TwinsanityEngineDriver(), WrathOfCortexEngineDriver()]

    public static func driver(forExtension ext: String) -> (any EngineDriver)? {
        let upper = ext.uppercased()
        return all.first { $0.recognizedExtensions.contains(upper) }
    }
}
