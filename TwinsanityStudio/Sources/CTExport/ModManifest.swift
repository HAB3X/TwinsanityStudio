import Foundation

/// The `modcrateinfo.txt`/`modcratesettings.txt` metadata read back out of a
/// `.crate` mod package — the read-side counterpart to `CrateMetadata`,
/// which `CrateExporter` only writes. Field names and text format match the
/// real `CrateModLoader` convention `CrateExporter`'s doc comment already
/// verifies against `CrateModLoader-master/CrateModAPI/ModCrates.cs`.
public struct ModManifest: Equatable, Sendable {
    public var name: String
    public var description: String
    public var author: String
    public var version: String
    public var targetGame: String
    public var modLoaderVersion: String
    /// Every `layer<N>/` folder actually present in the archive's real zip
    /// listing, in ascending order — not assumed to be a contiguous
    /// `0..<count` run, since a real crate can modify e.g. only `layer0`
    /// and `layer2`.
    public var layerIndices: [Int]
    /// Game-specific properties from `modcratesettings.txt`, empty if that
    /// file isn't present in the archive.
    public var settings: [String: String]
    public var hasIcon: Bool

    public init(
        name: String,
        description: String,
        author: String,
        version: String,
        targetGame: String,
        modLoaderVersion: String,
        layerIndices: [Int],
        settings: [String: String],
        hasIcon: Bool
    ) {
        self.name = name
        self.description = description
        self.author = author
        self.version = version
        self.targetGame = targetGame
        self.modLoaderVersion = modLoaderVersion
        self.layerIndices = layerIndices
        self.settings = settings
        self.hasIcon = hasIcon
    }
}
