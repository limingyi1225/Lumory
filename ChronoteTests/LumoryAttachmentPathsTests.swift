import XCTest
@testable import Lumory

final class LumoryAttachmentPathsTests: XCTestCase {
    private var createdURLs: [URL] = []

    override func tearDown() {
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        createdURLs.removeAll()
        super.tearDown()
    }

    func testExistingAudioURL_prefersLocalDirectoryOverLegacy() throws {
        let fileName = "attachment-paths-\(UUID().uuidString).m4a"
        let localDir = try LumoryAttachmentPaths.ensureLocalDirectory(for: .audio)
        let localURL = localDir.appendingPathComponent(fileName)
        let legacyURL = LumoryAttachmentPaths.legacyURL(fileName: fileName)

        try Data("local".utf8).write(to: localURL)
        try Data("legacy".utf8).write(to: legacyURL)
        createdURLs.append(contentsOf: [localURL, legacyURL])

        XCTAssertEqual(LumoryAttachmentPaths.existingAudioURL(fileName: fileName)?.path, localURL.path)
    }

    func testDeleteAllCopies_removesLocalDirectoryAndLegacyAudio() throws {
        let fileName = "attachment-paths-\(UUID().uuidString).m4a"
        let localDir = try LumoryAttachmentPaths.ensureLocalDirectory(for: .audio)
        let localURL = localDir.appendingPathComponent(fileName)
        let legacyURL = LumoryAttachmentPaths.legacyURL(fileName: fileName)

        try Data("local".utf8).write(to: localURL)
        try Data("legacy".utf8).write(to: legacyURL)
        createdURLs.append(contentsOf: [localURL, legacyURL])

        let removedCount = try LumoryAttachmentPaths.deleteAllCopies(fileName: fileName, kind: .audio)

        XCTAssertGreaterThanOrEqual(removedCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testNormalizedFileName_trimsAndRejectsUnsafeNames() {
        XCTAssertEqual(LumoryAttachmentPaths.normalizedFileName("  safe-name.m4a \n"), "safe-name.m4a")
        XCTAssertNil(LumoryAttachmentPaths.normalizedFileName(""))
        XCTAssertNil(LumoryAttachmentPaths.normalizedFileName("   "))
        XCTAssertNil(LumoryAttachmentPaths.normalizedFileName("."))
        XCTAssertNil(LumoryAttachmentPaths.normalizedFileName(".."))
        XCTAssertNil(LumoryAttachmentPaths.normalizedFileName("../escape.m4a"))
        XCTAssertNil(LumoryAttachmentPaths.normalizedFileName("folder/escape.m4a"))
        XCTAssertNil(LumoryAttachmentPaths.normalizedFileName("folder\\escape.m4a"))
    }

    func testDeleteAllCopies_rejectsUnsafeFileNameWithoutRemovingDirectory() throws {
        let localDir = try LumoryAttachmentPaths.ensureLocalDirectory(for: .audio)
        let sentinel = localDir.appendingPathComponent("attachment-paths-sentinel-\(UUID().uuidString).m4a")
        try Data("sentinel".utf8).write(to: sentinel)
        createdURLs.append(sentinel)

        XCTAssertThrowsError(try LumoryAttachmentPaths.deleteAllCopies(fileName: "", kind: .audio))
        XCTAssertThrowsError(try LumoryAttachmentPaths.deleteAllCopies(fileName: "../LumoryAudio", kind: .audio))

        XCTAssertTrue(FileManager.default.fileExists(atPath: localDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }
}
