import XCTest
import CTModels
@testable import CTExport

final class CrateArchiveManagerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Round-trip through the real CrateExporter (single layer0)

    func testReadManifestRoundTripsExportedMetadata() throws {
        let crateURL = tempDir.appendingPathComponent("mod.crate")
        let metadata = CrateMetadata(name: "Test Mod", description: "A test mod", author: "HAB3X", version: "2.1", targetGame: "Crash Twinsanity")
        try CrateExporter.export(files: [(relativePath: "level.rm2", data: Data([1, 2, 3]))], metadata: metadata, to: crateURL)

        let manifest = try CrateArchiveManager.readManifest(from: crateURL)
        XCTAssertEqual(manifest.name, "Test Mod")
        XCTAssertEqual(manifest.description, "A test mod")
        XCTAssertEqual(manifest.author, "HAB3X")
        XCTAssertEqual(manifest.version, "2.1")
        XCTAssertEqual(manifest.targetGame, "Crash Twinsanity")
        XCTAssertEqual(manifest.layerIndices, [0])
        XCTAssertFalse(manifest.hasIcon)
        XCTAssertTrue(manifest.settings.isEmpty)
    }

    func testListEntriesIncludesManifestAndLayerFiles() throws {
        let crateURL = tempDir.appendingPathComponent("mod.crate")
        let metadata = CrateMetadata(name: "Bundle", description: "", author: "", version: "1.0", targetGame: "Crash Twinsanity")
        let files: [(relativePath: String, data: Data)] = [
            (relativePath: "Wumpa/Wumpa.obj", data: Data("obj".utf8)),
            (relativePath: "Wumpa/texture_1.png", data: Data([0x89, 0x50]))
        ]
        try CrateExporter.export(files: files, metadata: metadata, to: crateURL)

        let entries = try CrateArchiveManager.listEntries(in: crateURL)
        XCTAssertTrue(entries.contains("modcrateinfo.txt"))
        XCTAssertTrue(entries.contains("layer0/Wumpa/Wumpa.obj"))
        XCTAssertTrue(entries.contains("layer0/Wumpa/texture_1.png"))

        let layerFiles = CrateArchiveManager.filesInLayer(0, entries: entries)
        XCTAssertEqual(layerFiles, ["Wumpa/Wumpa.obj", "Wumpa/texture_1.png"])
    }

    func testExtractLayerWritesFilesAtCorrectRelativePaths() throws {
        let crateURL = tempDir.appendingPathComponent("mod.crate")
        let metadata = CrateMetadata(name: "Bundle", description: "", author: "", version: "1.0", targetGame: "Crash Twinsanity")
        let files: [(relativePath: String, data: Data)] = [
            (relativePath: "Wumpa/Wumpa.obj", data: Data("obj-contents".utf8)),
            (relativePath: "Wumpa/animations/animation_2.json", data: Data("{}".utf8))
        ]
        try CrateExporter.export(files: files, metadata: metadata, to: crateURL)

        let destination = tempDir.appendingPathComponent("extracted")
        try CrateArchiveManager.extractLayer(0, from: crateURL, to: destination)

        let obj = try Data(contentsOf: destination.appendingPathComponent("Wumpa/Wumpa.obj"))
        XCTAssertEqual(obj, Data("obj-contents".utf8))
        let anim = try Data(contentsOf: destination.appendingPathComponent("Wumpa/animations/animation_2.json"))
        XCTAssertEqual(anim, Data("{}".utf8))
        // The layer0/ prefix itself must not appear in the extracted tree.
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("layer0").path))
    }

    func testReadManifestThrowsForZipWithNoManifest() throws {
        let plainZipSource = tempDir.appendingPathComponent("not-a-crate-src")
        try FileManager.default.createDirectory(at: plainZipSource, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: plainZipSource.appendingPathComponent("readme.txt"))
        let zipURL = tempDir.appendingPathComponent("not-a-crate.crate")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = plainZipSource
        process.arguments = ["-r", "-X", "-q", zipURL.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        XCTAssertThrowsError(try CrateArchiveManager.readManifest(from: zipURL)) { error in
            XCTAssertEqual(error as? CrateArchiveError, .manifestMissing)
        }
    }

    // MARK: - Multi-layer archive, built directly (CrateExporter only ever writes layer0)

    func testMultiLayerCrateReportsSparseLayerIndicesAndSettings() throws {
        let stageDir = tempDir.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: stageDir.appendingPathComponent("layer0"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stageDir.appendingPathComponent("layer2"), withIntermediateDirectories: true)
        try "!comment\nName=Sparse Mod\nAuthor=Someone\nVersion=1.0\nGame=Crash Twinsanity\nModLoaderVersion=1.0\n"
            .write(to: stageDir.appendingPathComponent("modcrateinfo.txt"), atomically: true, encoding: .utf8)
        try "!comment\nFogDensity=0.5\n"
            .write(to: stageDir.appendingPathComponent("modcratesettings.txt"), atomically: true, encoding: .utf8)
        try Data("layer0 file".utf8).write(to: stageDir.appendingPathComponent("layer0/a.txt"))
        try Data("layer2 file".utf8).write(to: stageDir.appendingPathComponent("layer2/b.txt"))

        let crateURL = tempDir.appendingPathComponent("sparse.crate")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = stageDir
        process.arguments = ["-r", "-X", "-q", crateURL.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let manifest = try CrateArchiveManager.readManifest(from: crateURL)
        XCTAssertEqual(manifest.name, "Sparse Mod")
        XCTAssertEqual(manifest.layerIndices, [0, 2])
        XCTAssertEqual(manifest.settings["FogDensity"], "0.5")

        let entries = try CrateArchiveManager.listEntries(in: crateURL)
        XCTAssertEqual(CrateArchiveManager.filesInLayer(1, entries: entries), [])
        XCTAssertEqual(CrateArchiveManager.filesInLayer(2, entries: entries), ["b.txt"])
    }

    // MARK: - Nested crates (modcrateinfo.txt not at the zip root)

    func testNestedCrateOffsetsManifestLayerAndExtractLookups() throws {
        let stageDir = tempDir.appendingPathComponent("stage")
        let wrapperDir = stageDir.appendingPathComponent("MyMod")
        try FileManager.default.createDirectory(at: wrapperDir.appendingPathComponent("layer0/Wumpa"), withIntermediateDirectories: true)
        try "!comment\nName=Nested Mod\nVersion=1.0\n"
            .write(to: wrapperDir.appendingPathComponent("modcrateinfo.txt"), atomically: true, encoding: .utf8)
        try Data("nested contents".utf8).write(to: wrapperDir.appendingPathComponent("layer0/Wumpa/fruit.txt"))

        let crateURL = tempDir.appendingPathComponent("nested.crate")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = stageDir
        process.arguments = ["-r", "-X", "-q", crateURL.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let manifest = try CrateArchiveManager.readManifest(from: crateURL)
        XCTAssertEqual(manifest.name, "Nested Mod")
        XCTAssertEqual(manifest.nestedPath, "MyMod/")
        XCTAssertEqual(manifest.layerIndices, [0])

        let entries = try CrateArchiveManager.listEntries(in: crateURL)
        XCTAssertEqual(CrateArchiveManager.filesInLayer(0, entries: entries, nestedPath: manifest.nestedPath), ["Wumpa/fruit.txt"])

        let destination = tempDir.appendingPathComponent("nested-extracted")
        try CrateArchiveManager.extractLayer(0, from: crateURL, to: destination, nestedPath: manifest.nestedPath)
        let contents = try Data(contentsOf: destination.appendingPathComponent("Wumpa/fruit.txt"))
        XCTAssertEqual(contents, Data("nested contents".utf8))
    }

    // MARK: - Region gating

    func testDeclaredRegionParsesFromSettingsKey() {
        let withRegion = ModManifest(name: "x", description: "", author: "", version: "1.0", targetGame: "", modLoaderVersion: "", layerIndices: [], settings: ["GameRegion": "PAL"], hasIcon: false)
        XCTAssertEqual(withRegion.declaredRegion, .pal)

        let withoutRegion = ModManifest(name: "x", description: "", author: "", version: "1.0", targetGame: "", modLoaderVersion: "", layerIndices: [], settings: [:], hasIcon: false)
        XCTAssertNil(withoutRegion.declaredRegion)

        let unrecognized = ModManifest(name: "x", description: "", author: "", version: "1.0", targetGame: "", modLoaderVersion: "", layerIndices: [], settings: ["GameRegion": "Mars"], hasIcon: false)
        XCTAssertNil(unrecognized.declaredRegion)
    }
}
