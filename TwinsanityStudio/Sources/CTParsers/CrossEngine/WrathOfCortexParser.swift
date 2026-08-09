import Foundation
import CTCore
import CTModels

/// "Cross-Engine Chunk Stitcher" (roadmap 5.3): standalone decoders for
/// *Wrath of Cortex*'s `.CRT`/`.WMP` files — not part of the `.RM2`/`.SM2`
/// chunk-header system the rest of `CTParsers` decodes, since WoC uses a
/// completely different, simpler flat binary layout. See
/// `WOCCrateFile`'s doc comment for the "ported, not verified against real
/// WoC bytes" caveat.
public enum WrathOfCortexParser {
    public enum ParseError: Error {
        case truncated
    }

    /// `uint32 header` + `uint16 groupCount`, then per group: first crate's
    /// `Vector3 pos`, `uint16 id`, `uint16 crateCount`, `uint16 unkFlags`,
    /// `Vector3 rot`, first crate's `byte[10]` + 4 type bytes + `byte[14]`,
    /// then `crateCount - 1` more crates (`Vector3 pos` + `byte[10]` + 4
    /// type bytes + `byte[14]` each, no group header repeated).
    public static func parseCrateFile(_ data: Data) throws -> WOCCrateFile {
        var cursor = BinaryCursor(data: data)
        let header = try cursor.readUInt32()
        let groupCount = try cursor.readUInt16()
        var groups: [WOCCrateGroup] = []
        groups.reserveCapacity(Int(groupCount))

        for _ in 0..<groupCount {
            let firstPosition = try cursor.readVector3()
            let id = try cursor.readUInt16()
            let crateCount = try cursor.readUInt16()
            _ = try cursor.readUInt16() // unkFlags
            let rotation = try cursor.readVector3()
            _ = try cursor.readBytes(10) // first crate's unkFlags
            let firstType = try cursor.readUInt8()
            let firstTypeTT = try cursor.readUInt8()
            let firstType3 = try cursor.readUInt8()
            let firstType4 = try cursor.readUInt8()
            _ = try cursor.readBytes(14) // first crate's unkFlags2

            var crates = [WOCCrate(position: firstPosition, rawType: firstType, typeTT: firstTypeTT, type3: firstType3, type4: firstType4)]
            guard crateCount > 0 else {
                groups.append(WOCCrateGroup(id: id, rotation: rotation, crates: crates))
                continue
            }
            for _ in 0..<(crateCount - 1) {
                let position = try cursor.readVector3()
                _ = try cursor.readBytes(10)
                let type = try cursor.readUInt8()
                let typeTT = try cursor.readUInt8()
                let type3 = try cursor.readUInt8()
                let type4 = try cursor.readUInt8()
                _ = try cursor.readBytes(14)
                crates.append(WOCCrate(position: position, rawType: type, typeTT: typeTT, type3: type3, type4: type4))
            }
            groups.append(WOCCrateGroup(id: id, rotation: rotation, crates: crates))
        }

        return WOCCrateFile(header: header, groups: groups)
    }

    /// `uint32 count` + `count * Vector3`.
    public static func parseWumpaFile(_ data: Data) throws -> WOCWumpaFile {
        var cursor = BinaryCursor(data: data)
        let count = try cursor.readUInt32()
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(Int(count))
        for _ in 0..<count { positions.append(try cursor.readVector3()) }
        return WOCWumpaFile(positions: positions)
    }
}
