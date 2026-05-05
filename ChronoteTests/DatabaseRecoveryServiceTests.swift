import XCTest
@testable import Lumory

final class DatabaseRecoveryServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DatabaseRecoveryServiceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testBackupRestoreAndDeleteIncludeSQLiteCKSidecar() throws {
        let source = tempDir.appendingPathComponent("Model.sqlite")
        try writeDatabaseFileSet(at: source, marker: "source")

        let backupDir = tempDir.appendingPathComponent("Backups", isDirectory: true)
        guard let backup = DatabaseRecoveryService.shared.createBackup(of: source, in: backupDir) else {
            XCTFail("Expected backup to be created")
            return
        }

        assertDatabaseFileSetExists(at: backup)
        XCTAssertEqual(try String(contentsOf: sidecarURL(for: backup, ext: "sqlite-ck")), "source-sqlite-ck")

        let restored = tempDir.appendingPathComponent("Restored.sqlite")
        DatabaseRecoveryService.shared.restoreFromBackup(backupURL: backup, to: restored)

        assertDatabaseFileSetExists(at: restored)
        XCTAssertEqual(try String(contentsOf: sidecarURL(for: restored, ext: "sqlite-ck")), "source-sqlite-ck")

        DatabaseRecoveryService.shared.deleteCorruptedFiles(at: restored)
        assertDatabaseFileSetMissing(at: restored)
    }

    func testCleanupOldBackupsRemovesSQLiteCKSidecar() throws {
        let backupDir = tempDir.appendingPathComponent("CleanupBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let old = backupDir.appendingPathComponent("old.sqlite")
        let newest = backupDir.appendingPathComponent("newest.sqlite")
        try writeDatabaseFileSet(at: old, marker: "old")
        try writeDatabaseFileSet(at: newest, marker: "new")
        try setCreationDate(Date(timeIntervalSince1970: 1), for: old)
        try setCreationDate(Date(timeIntervalSince1970: 2), for: newest)

        DatabaseRecoveryService.shared.cleanupOldBackups(in: backupDir, keepLast: 1)

        assertDatabaseFileSetMissing(at: old)
        assertDatabaseFileSetExists(at: newest)
        XCTAssertEqual(try String(contentsOf: sidecarURL(for: newest, ext: "sqlite-ck")), "new-sqlite-ck")
    }

    private func writeDatabaseFileSet(at sqliteURL: URL, marker: String) throws {
        try marker.write(to: sqliteURL, atomically: true, encoding: .utf8)
        for ext in DatabaseRecoveryService.sqliteSidecarExtensions {
            try "\(marker)-\(ext)".write(
                to: sidecarURL(for: sqliteURL, ext: ext),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func assertDatabaseFileSetExists(at sqliteURL: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(FileManager.default.fileExists(atPath: sqliteURL.path), file: file, line: line)
        for ext in DatabaseRecoveryService.sqliteSidecarExtensions {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: sidecarURL(for: sqliteURL, ext: ext).path),
                "\(ext) should exist",
                file: file,
                line: line
            )
        }
    }

    private func assertDatabaseFileSetMissing(at sqliteURL: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: sqliteURL.path), file: file, line: line)
        for ext in DatabaseRecoveryService.sqliteSidecarExtensions {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: sidecarURL(for: sqliteURL, ext: ext).path),
                "\(ext) should be removed",
                file: file,
                line: line
            )
        }
    }

    private func sidecarURL(for sqliteURL: URL, ext: String) -> URL {
        sqliteURL.deletingPathExtension().appendingPathExtension(ext)
    }

    private func setCreationDate(_ date: Date, for sqliteURL: URL) throws {
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: sqliteURL.path)
    }
}
