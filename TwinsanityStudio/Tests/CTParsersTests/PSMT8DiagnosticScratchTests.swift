import XCTest
@testable import CTParsers

final class PSMT8DiagnosticScratchTests: XCTestCase {
    func testDiagnoseByteFootprints() {
        let width = 16, height = 16

        // Which physical bytes does writeTexPSMT8 touch, for a 16x16 image?
        let ez1 = EzSwizzle()
        ez1.cleanGs()
        let sentinel = [UInt8](repeating: 0xAB, count: width * height)
        ez1.writeTexPSMT8(dbp: 0, dbwIn: 2, dsax: 0, dsay: 0, rrw: width, rrh: height, data: sentinel)
        var probe1 = [UInt8](repeating: 0, count: 256 * 4)
        ez1.readTexPSMCT32(dbp: 0, dbw: 1, dsax: 0, dsay: 0, rrw: 32, rrh: 32, into: &probe1)
        var maxNonzero1 = -1
        for (i, b) in probe1.enumerated() where b != 0 { maxNonzero1 = i }
        print("DIAG: writeTexPSMT8(16x16) touched bytes up to index \(maxNonzero1) when read back via PSMCT32(rrw=32,rrh=32)")

        // Which physical bytes does a 256-entry writeTexPSMCT32 CLUT touch at dbp=8?
        let ez2 = EzSwizzle()
        ez2.cleanGs()
        let clutSentinel = [UInt8](repeating: 0xCD, count: 256 * 4)
        ez2.writeTexPSMCT32(dbp: 8, dbw: 1, dsax: 0, dsay: 0, rrw: 16, rrh: 16, data: clutSentinel)
        var probe2 = [UInt8](repeating: 0, count: 512 * 4)
        ez2.readTexPSMCT32(dbp: 0, dbw: 1, dsax: 0, dsay: 0, rrw: 32, rrh: 64, into: &probe2)
        var minNonzero2 = Int.max
        var maxNonzero2 = -1
        for (i, b) in probe2.enumerated() where b != 0 {
            minNonzero2 = min(minNonzero2, i)
            maxNonzero2 = max(maxNonzero2, i)
        }
        print("DIAG: writeTexPSMCT32(dbp=8, 16x16 clut) touched byte range \(minNonzero2)...\(maxNonzero2) when read back via PSMCT32(rrw=32,rrh=64)")

        XCTAssertTrue(true)
    }
}
