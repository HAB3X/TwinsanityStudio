import Foundation

/// A `GameObject` (`Object` section, sub-ID 0 under `Code`) — the game-logic
/// definition an `Instance.objectID` actually refers to. Ported from
/// `Twinsanity/Items/Code/GameObject.cs`'s `Load`, decoded only through the
/// `OGIs` list: everything after that (the optional instance-properties
/// block, the optional linked-ID block, and a trailing script-bytecode
/// command tree) isn't needed to answer "what does this object look like,"
/// and this codebase doesn't decode script bytecode anywhere else either
/// (see `LevelViewerWindow`'s own "Level Events" doc comment) — so it's
/// deliberately left unparsed rather than guessed at.
public struct GameObjectInfo: Sendable {
    public let id: UInt32
    public let name: String
    /// `GraphicsInfo` (OGI) record IDs this object can render as — index 0
    /// is the default; `Instance.unknownUInt32List2[0]`, when non-zero,
    /// selects a different entry instead (see `AssetResolver.
    /// resolveInstanceObject`'s doc comment for exactly how, ported from
    /// `RMViewer.cs`). `65535` is the on-disk "no value" sentinel, kept
    /// as-is rather than translated to `nil` so callers can match the
    /// reference logic's own sentinel check directly.
    public let ogiIDs: [UInt32]

    public init(id: UInt32, name: String, ogiIDs: [UInt32]) {
        self.id = id
        self.name = name
        self.ogiIDs = ogiIDs
    }
}
