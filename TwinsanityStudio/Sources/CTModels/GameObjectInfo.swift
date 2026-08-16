import Foundation

/// A `GameObject` (`Object` section, sub-ID 0 under `Code`) — the game-logic
/// definition an `Instance.objectID` actually refers to. Ported in full from
/// `Twinsanity/Items/Code/GameObject.cs`'s `Load`/`Save`/`GetSize`.
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
    /// Gates the two optional trailing blocks below (`0x20000000` for
    /// `instanceProperties`, `0x40000000` for `linkedIDs`) — kept raw
    /// rather than exposing two derived `Bool`s since the reference
    /// itself treats this as one opaque bitfield with only those two bits
    /// confirmed.
    public let unkBitfield: UInt32
    /// Untyped `uint32` script-slot list — real, decoded, but the
    /// reference tool itself never gives these individual meaning beyond
    /// "a `UI32` slot."
    public let ui32: [UInt32]
    public let animIDs: [UInt16]
    public let scriptIDs: [UInt16]
    public let objectIDs: [UInt16]
    public let soundIDs: [UInt16]
    /// Present only when `unkBitfield & 0x20000000 != 0`.
    public let instanceProperties: InstanceProperties?
    /// Present only when `unkBitfield & 0x40000000 != 0` — the ID lists
    /// `GameObject.FillPackage` walks to bundle a mod-crate's real
    /// dependency closure (linked objects/OGIs/anims/CodeModels/scripts/
    /// sounds). Not yet consumed by this build's own `CrateExporter`
    /// (see that type's doc comment for current scope), but decoded here
    /// since it's real, unambiguous on-disk data.
    public let linkedIDs: LinkedIDs?
    /// This object's own trailing script-bytecode command chain — the
    /// exact same `Script.MainScript.ScriptCommand` format `CustomAgent`
    /// records use (see `CustomAgentParser.readCommandChain`), attached
    /// directly to the object rather than to a separate `CustomAgent`
    /// record. Empty when the record's own `scriptCommandsAmount` is `0`.
    public let scriptCommands: [AgentLabCommand]

    public struct InstanceProperties: Sendable {
        public let pHeader: UInt32
        public let pUI32: UInt32
        public let flags: [UInt32]
        public let floats: [Float]
        public let integers: [UInt32]

        public init(pHeader: UInt32, pUI32: UInt32, flags: [UInt32], floats: [Float], integers: [UInt32]) {
            self.pHeader = pHeader
            self.pUI32 = pUI32
            self.flags = flags
            self.floats = floats
            self.integers = integers
        }
    }

    public struct LinkedIDs: Sendable {
        public let flag: UInt32
        public let objects: [UInt16]
        public let ogis: [UInt16]
        public let anims: [UInt16]
        public let codeModels: [UInt16]
        public let scripts: [UInt16]
        public let unk: [UInt16]
        public let sounds: [UInt16]

        public init(flag: UInt32, objects: [UInt16], ogis: [UInt16], anims: [UInt16], codeModels: [UInt16], scripts: [UInt16], unk: [UInt16], sounds: [UInt16]) {
            self.flag = flag
            self.objects = objects
            self.ogis = ogis
            self.anims = anims
            self.codeModels = codeModels
            self.scripts = scripts
            self.unk = unk
            self.sounds = sounds
        }
    }

    public init(
        id: UInt32,
        name: String,
        ogiIDs: [UInt32],
        unkBitfield: UInt32 = 0,
        ui32: [UInt32] = [],
        animIDs: [UInt16] = [],
        scriptIDs: [UInt16] = [],
        objectIDs: [UInt16] = [],
        soundIDs: [UInt16] = [],
        instanceProperties: InstanceProperties? = nil,
        linkedIDs: LinkedIDs? = nil,
        scriptCommands: [AgentLabCommand] = []
    ) {
        self.id = id
        self.name = name
        self.ogiIDs = ogiIDs
        self.unkBitfield = unkBitfield
        self.ui32 = ui32
        self.animIDs = animIDs
        self.scriptIDs = scriptIDs
        self.objectIDs = objectIDs
        self.soundIDs = soundIDs
        self.instanceProperties = instanceProperties
        self.linkedIDs = linkedIDs
        self.scriptCommands = scriptCommands
    }
}
