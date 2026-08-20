import Foundation
import simd

/// Decoder for WoC `.LGT` (lighting) files -- see `LGT_Spec.md` at the
/// repo root for the full investigation history this is built on.
///
/// **CONFIRMED, file-level framing** (checked against all 37 real files,
/// zero exceptions): `fileSize = 4 (leading count) + 24 (header) +
/// 55*count + 12*K`, where `count` is the leading `UInt32LE` and `K` is a
/// real, present count of "extended" 67-byte records mixed in among the
/// otherwise-uniform 55-byte ones -- **which records are extended is not
/// known**, so this parser only decodes files where `K == 0` (confirmed
/// on 8 of the 37 real files -- every other file's `count`-many records
/// really are all 55 bytes, no guessing needed). `K > 0` files have their
/// record region exposed as one raw, undivided blob instead of a guess.
///
/// **CONFIRMED, per-record "normal" shape** (independently re-verified
/// against real bytes multiple times, most recently by directly decoding
/// `AIRSHIP.LGT`'s own light 0 field-by-field): `position:Vec3` +
/// `extra:Float32` (16 bytes), `radius:Float32` (4 bytes),
/// `colorByte:UInt8x3` (3 bytes, confirmed via WoC's own decompiled
/// symbol table -- `edlightMakeNUCOLOUR3`, a real `NUCOLOUR3` type with
/// no alpha channel), `colorFloat:Float32x3` (12 bytes, confirmed to
/// equal `colorByte/255` to 3 decimal places on every real "normal"
/// record checked), then a 20-byte `tail` that's real but not decoded.
///
/// **A second record shape exists and this parser does NOT attempt to
/// decode it** -- confirmed real (not a bug in reading the normal shape)
/// via a hand check on `AIRSHIP.LGT`'s own light 1: computed "radius"
/// comes out negative and "colorByte"/"colorFloat" don't cross-validate
/// at all. Every record is independently validated (`radius >= 0` and
/// `colorFloat` matching `colorByte/255` within a real tolerance) before
/// being trusted -- a record that fails validation is exposed as `nil`
/// in `File.lights` with its raw 55 bytes preserved in
/// `File.rawRecords`, never silently misdecoded. **Real, useful
/// structure found in when this happens**: on both real `K == 0` files
/// that have a variant record at all (`AIRSHIP.LGT`, `WESTERN.LGT`), it
/// is always the file's *last* record -- a small sample (2 of 2), not a
/// proven rule, so this parser doesn't rely on it structurally (every
/// record is still independently validated on its own merits), but it's
/// worth knowing when interpreting `nil` entries.
public enum WOCLightParser {
    public enum ParseError: Error, Equatable {
        case truncated
    }

    /// One real "normal"-shape light record. See this file's own doc
    /// comment for exactly what's confirmed.
    public struct Light {
        /// Relative offset 0-11 -- a real position, cross-checked
        /// against that same level's `INST` coordinate range in earlier
        /// investigation, but the per-axis assignment (whether this is
        /// literally `(x,y,z)` in that order) is not independently
        /// confirmed here.
        public let position: SIMD3<Float>
        /// Relative offset 12-15 -- a real, present 4th value alongside
        /// `position`; not understood.
        public let extra: Float
        /// Relative offset 16-19.
        public let radius: Float
        /// Relative offset 20-22 -- confirmed `NUCOLOUR3` (no alpha).
        public let colorByte: (UInt8, UInt8, UInt8)
        /// Relative offset 23-34 -- confirmed to equal `colorByte/255`.
        public let colorFloat: SIMD3<Float>
        /// Relative offset 35-54 (20 bytes) -- real, present, not
        /// decoded (contains at least two small `UInt32` fields per
        /// earlier investigation; exposed raw rather than guessed at).
        public let tail: Data
    }

    public struct File {
        /// The header's four `Int32`s -- real, present; only a rough,
        /// unconfirmed correlation with `K` is known (see `LGT_Spec.md`).
        public let header: (Int32, Int32, Int32, Int32)
        /// Two floats following the header ints -- real, not understood.
        public let headerFloats: (Float, Float)
        /// `K` from the confirmed file-size formula -- the count of
        /// "extended" 67-byte records mixed in among the 55-byte ones.
        public let extendedRecordCount: Int
        /// One entry per `count`-many records, in file order. `nil` when
        /// either this specific record failed validation (the second,
        /// undecoded shape) or `extendedRecordCount != 0` for the whole
        /// file (record boundaries aren't reliably known at all in that
        /// case -- see `rawRecordBlob`).
        public let lights: [Light?]
        /// Every record's own raw 55 bytes, always present when
        /// `extendedRecordCount == 0` (one entry per `lights` element,
        /// same order) -- empty when `extendedRecordCount != 0`, since
        /// individual record boundaries aren't known in that case (see
        /// `rawRecordBlob` for the whole region instead).
        public let rawRecords: [Data]
        /// The entire record region as one undivided blob -- always
        /// present, the only thing available when `extendedRecordCount
        /// != 0` (record boundaries unknown), redundant with
        /// `rawRecords`/`lights` when `extendedRecordCount == 0`.
        public let rawRecordBlob: Data
    }

    public static func parse(_ data: Data) throws -> File {
        let bytes = [UInt8](data)
        guard bytes.count >= 28 else { throw ParseError.truncated }
        let count = Int(leUInt32(bytes, 0))
        let header = (leInt32(bytes, 4), leInt32(bytes, 8), leInt32(bytes, 12), leInt32(bytes, 16))
        let headerFloats = (leFloat32(bytes, 20), leFloat32(bytes, 24))

        let recordRegionStart = 28
        guard count >= 0, bytes.count >= recordRegionStart else { throw ParseError.truncated }
        let recordRegionLength = bytes.count - recordRegionStart
        guard recordRegionLength >= 55 * count else { throw ParseError.truncated }
        let remainder = recordRegionLength - 55 * count
        guard remainder % 12 == 0 else { throw ParseError.truncated }
        let extendedRecordCount = remainder / 12

        let rawRecordBlob = Data(bytes[recordRegionStart...])

        guard extendedRecordCount == 0 else {
            // Record boundaries aren't reliably known when extended
            // records are mixed in -- expose the whole region raw rather
            // than guess at a 55-byte stride that would desync after the
            // first extended record.
            return File(header: header, headerFloats: headerFloats, extendedRecordCount: extendedRecordCount,
                        lights: Array(repeating: nil, count: count), rawRecords: [], rawRecordBlob: rawRecordBlob)
        }

        var lights: [Light?] = []
        var rawRecords: [Data] = []
        lights.reserveCapacity(count)
        rawRecords.reserveCapacity(count)
        for i in 0..<count {
            let base = recordRegionStart + i * 55
            let raw = Data(bytes[base..<(base + 55)])
            rawRecords.append(raw)
            lights.append(parseValidatedLight(bytes, base: base))
        }
        return File(header: header, headerFloats: headerFloats, extendedRecordCount: extendedRecordCount,
                    lights: lights, rawRecords: rawRecords, rawRecordBlob: rawRecordBlob)
    }

    /// Decodes one 55-byte record under the confirmed "normal" shape and
    /// independently validates it before returning -- `nil` if the
    /// record doesn't validate (the second, undecoded shape), rather
    /// than trusting the decode unconditionally.
    private static func parseValidatedLight(_ bytes: [UInt8], base: Int) -> Light? {
        let position = SIMD3(leFloat32(bytes, base), leFloat32(bytes, base + 4), leFloat32(bytes, base + 8))
        let extra = leFloat32(bytes, base + 12)
        let radius = leFloat32(bytes, base + 16)
        let colorByte: (UInt8, UInt8, UInt8) = (bytes[base + 20], bytes[base + 21], bytes[base + 22])
        let colorFloat = SIMD3(leFloat32(bytes, base + 23), leFloat32(bytes, base + 27), leFloat32(bytes, base + 31))
        let tail = Data(bytes[(base + 35)..<(base + 55)])

        guard radius.isFinite, radius >= 0 else { return nil }
        guard colorFloat.x.isFinite, colorFloat.y.isFinite, colorFloat.z.isFinite else { return nil }
        let expected = SIMD3(Float(colorByte.0), Float(colorByte.1), Float(colorByte.2)) / 255.0
        guard simd_length(colorFloat - expected) < 0.01 else { return nil }

        return Light(position: position, extra: extra, radius: radius, colorByte: colorByte, colorFloat: colorFloat, tail: tail)
    }

    private static func leUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func leInt32(_ b: [UInt8], _ o: Int) -> Int32 {
        Int32(bitPattern: leUInt32(b, o))
    }

    private static func leFloat32(_ b: [UInt8], _ o: Int) -> Float {
        Float(bitPattern: leUInt32(b, o))
    }
}
