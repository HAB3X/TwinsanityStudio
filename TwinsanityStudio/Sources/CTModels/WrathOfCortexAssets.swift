import Foundation
import simd

/// "Cross-Engine Chunk Stitcher" (roadmap 5.3): real, decoded data from
/// *Crash Twinsanity: The Wrath of Cortex* — a different TT-engine game
/// with an entirely different on-disk format from this build's own
/// `.RM2`/`.SM2`/`.BH`/`.BD`. Ported field-for-field from CrateModLoader's
/// real, working `TWOC_File_CRT.cs`/`TWOC_File_WMP.cs` (a community modding
/// tool with an actual shipped encoder/decoder for these formats) —
/// **not** independently verified against real Wrath of Cortex game files
/// in this session, since no Wrath of Cortex disc image is available here
/// (unlike every other format in this codebase, which is checked against
/// the mounted Crash Twinsanity disc before being trusted). Treat this as
/// ported-and-plausible, not confirmed-against-real-bytes.
public enum WOCCrateType: UInt8, Sendable, Codable {
    case null = 255
    case wireframe = 0
    case blank = 1
    case life = 2
    case aku = 3
    case bounce = 4
    case pickup = 5
    case fruit = 6
    case checkpoint = 7
    case slot = 8
    case tnt = 9
    case time1 = 10
    case time2 = 11
    case time3 = 12
    case ironBounce = 13
    case ironSwitch = 14
    case steel = 15
    case nitro = 16
    case nitroSwitch = 17
    case proximity = 18
    case reinforced = 19
    case invisibility = 20
}

/// One crate. `.CRT` files store 4 type bytes per crate (`type`/`typeTT`/
/// `type3`/`type4`) — the reference tool itself doesn't explain the other
/// 3, so they're kept alongside `type` rather than discarded, same
/// "preserve real bytes, don't guess their meaning" discipline as this
/// build's own `PlacedInstance.unknownUInt32List` fields.
public struct WOCCrate: Sendable, Codable {
    public var position: SIMD3<Float>
    public var type: WOCCrateType?
    public var rawType: UInt8
    public var typeTT: UInt8
    public var type3: UInt8
    public var type4: UInt8

    public init(position: SIMD3<Float>, rawType: UInt8, typeTT: UInt8, type3: UInt8, type4: UInt8) {
        self.position = position
        self.rawType = rawType
        self.type = WOCCrateType(rawValue: rawType)
        self.typeTT = typeTT
        self.type3 = type3
        self.type4 = type4
    }
}

public struct WOCCrateGroup: Sendable, Codable {
    public var id: UInt16
    public var rotation: SIMD3<Float>
    public var crates: [WOCCrate]

    public init(id: UInt16, rotation: SIMD3<Float>, crates: [WOCCrate]) {
        self.id = id
        self.rotation = rotation
        self.crates = crates
    }
}

/// A decoded `.CRT` (crate positions) file.
public struct WOCCrateFile: Sendable, Codable {
    public var header: UInt32
    public var groups: [WOCCrateGroup]

    public init(header: UInt32, groups: [WOCCrateGroup]) {
        self.header = header
        self.groups = groups
    }

    public var totalCrateCount: Int { groups.reduce(0) { $0 + $1.crates.count } }
}

/// A decoded `.WMP` (Wumpa fruit positions) file — just a flat list of
/// points, max 256 per the reference tool's own `Save`.
public struct WOCWumpaFile: Sendable, Codable {
    public var positions: [SIMD3<Float>]

    public init(positions: [SIMD3<Float>]) {
        self.positions = positions
    }
}
