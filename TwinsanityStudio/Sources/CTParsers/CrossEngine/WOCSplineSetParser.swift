import Foundation
import simd

/// Decodes WoC `.GSC`'s `SST0` section -- the real handler is
/// `ReadNuIFFGSplineSet` (see `SST0_Spec.md` and
/// `WOCContainerParser.parseFooterHeader(_:)`'s doc comment for the
/// investigation history this builds on; `SST0` was previously
/// considered "genuinely harder than `.VIS`... its real structure is
/// still completely open").
///
/// **CONFIRMED, exact byte consumption across the entire real corpus (41
/// of 41 real files with a nonempty `SST0` blob)**: found the real
/// function body in `Games Files/Reference Files/OpenCrashWOC-main/code/
/// src/nu3dx/nuscene.c:132-159` (marked `//MATCH NGC`), a genuinely
/// different organizing idea from both of this doc's previously-refuted
/// hypotheses -- not a separate header table, not a `.VIS`-style flat
/// point-count-then-points scheme. Per that source, after the already-
/// confirmed outer `firstField:UInt32(numSplines) blobLength:UInt32
/// blob:Bytes(blobLength)` framing (`WOCContainerParser.parseFooterHeader`),
/// the blob holds `numSplines` back-to-back records, each:
/// ```
/// SplineRecord := len:Int16LE pad:Int16LE(unused) nameOffset:Int16LE pad2:Int16LE(unused)
///                 Vec3(len)   -- len*12 bytes, immediately inline, no separate point blob
/// ```
/// an 8-byte inline header directly followed by that spline's own point
/// data -- i.e. header+points+header+points..., self-describing via each
/// record's own `len`.
///
/// **One real correction to the decompiled source's exact byte offsets**:
/// the C source reads `len`/`nameOffset` via `*(s16*)(temp+2)` (i.e. at
/// sub-offsets 2 and 6 within each 4-byte slot) -- but direct byte
/// verification on `FARM.GSC` (`blob.count=68`, `numSplines=1`, real
/// bytes `05 00 00 00 8e 00 00 00 ...`) shows `len=5` sits at sub-offset
/// **0**, not 2 (`5*12+8 == 68` exactly; reading at offset+2 instead gives
/// `len=0`, which cannot be right for a 68-byte single-spline blob).
/// Trusting the real bytes over that one pointer-arithmetic detail
/// (plausibly a decompiler artifact, not raw disassembly) is what
/// achieves the 41/41 exact-fit result -- verified programmatically, not
/// sampled: every real `SST0` blob's `numSplines` back-to-back records
/// consume the blob to the exact byte, zero leftover, zero overrun.
///
/// **Not yet confirmed**: what `nameOffset` resolves against (the real
/// source reads `gsc->nametable + nameOffset`, implying a shared name
/// table populated elsewhere in the same file -- not verified here,
/// exposed as a raw offset rather than a resolved name).
public enum WOCSplineSetParser {
    public enum ParseError: Error, Equatable {
        case truncated
        case invalidLength(splineIndex: Int, len: Int)
    }

    /// One real spline -- `points.count == len` from the confirmed
    /// on-disk record.
    public struct Spline {
        /// Relative byte offset into the file's own name table (not
        /// resolved here -- see this type's own doc comment).
        public let nameOffset: Int
        public let points: [SIMD3<Float>]
    }

    public struct File {
        public let numSplines: Int
        public let splines: [Spline]
        /// The 12-byte trailer following the blob -- see
        /// `WOCContainerParser.parseFooterHeader(_:)`'s doc comment for
        /// what's confirmed about it (a minority of files echo the
        /// section's own total length here).
        public let trailer: Data
    }

    /// Parses an already-extracted `SST0` section payload (i.e.
    /// `WOCContainerParser.Section.payload` for the section whose
    /// `tag == "SST0"`).
    public static func parse(_ sst0Payload: Data) throws -> File {
        let (firstField, blob, trailer) = try WOCContainerParser.parseFooterHeader(sst0Payload)
        let numSplines = Int(firstField)
        guard numSplines >= 0 else { throw ParseError.truncated }
        guard numSplines > 0 else { return File(numSplines: 0, splines: [], trailer: trailer) }

        let bytes = [UInt8](blob)
        var cursor = 0
        var splines: [Spline] = []
        splines.reserveCapacity(numSplines)
        for i in 0..<numSplines {
            guard cursor + 8 <= bytes.count else { throw ParseError.truncated }
            let len = Int(leInt16(bytes, cursor))
            let nameOffset = Int(leInt16(bytes, cursor + 4))
            guard len >= 0 else { throw ParseError.invalidLength(splineIndex: i, len: len) }
            cursor += 8
            guard cursor + len * 12 <= bytes.count else { throw ParseError.truncated }
            var points: [SIMD3<Float>] = []
            points.reserveCapacity(len)
            for p in 0..<len {
                let base = cursor + p * 12
                points.append(SIMD3(leFloat32(bytes, base), leFloat32(bytes, base + 4), leFloat32(bytes, base + 8)))
            }
            splines.append(Spline(nameOffset: nameOffset, points: points))
            cursor += len * 12
        }
        return File(numSplines: numSplines, splines: splines, trailer: trailer)
    }

    private static func leInt16(_ b: [UInt8], _ o: Int) -> Int16 {
        Int16(bitPattern: UInt16(b[o]) | (UInt16(b[o + 1]) << 8))
    }

    private static func leUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func leFloat32(_ b: [UInt8], _ o: Int) -> Float {
        Float(bitPattern: leUInt32(b, o))
    }
}
