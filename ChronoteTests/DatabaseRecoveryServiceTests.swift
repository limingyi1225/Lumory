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
        XCTAssertEqual(try String(contentsOf: supportBlobURL(for: backup)), "source-external-blob")

        let restored = tempDir.appendingPathComponent("Restored.sqlite")
        XCTAssertTrue(DatabaseRecoveryService.shared.restoreFromBackup(backupURL: backup, to: restored))

        assertDatabaseFileSetExists(at: restored)
        XCTAssertEqual(try String(contentsOf: sidecarURL(for: restored, ext: "sqlite-ck")), "source-sqlite-ck")
        XCTAssertEqual(try String(contentsOf: supportBlobURL(for: restored)), "source-external-blob")

        DatabaseRecoveryService.shared.deleteCorruptedFiles(at: restored)
        assertDatabaseFileSetMissing(at: restored)
    }

    func testRestoreFromBackupFailureReturnsFalseAndLeavesNoTargetStore() throws {
        let missingBackup = tempDir.appendingPathComponent("Missing.sqlite")
        let restored = tempDir.appendingPathComponent("RestoredFailure.sqlite")
        try writeDatabaseFileSet(at: restored, marker: "stale-target")

        XCTAssertFalse(DatabaseRecoveryService.shared.restoreFromBackup(backupURL: missingBackup, to: restored))
        assertDatabaseFileSetMissing(at: restored)
    }

    func testBackupRestoreAndDeleteIncludeAllExternalStorageDirectoryCandidates() throws {
        let sourceTemplate = tempDir.appendingPathComponent("CandidateSource.sqlite")
        let candidateCount = DatabaseRecoveryService.externalStorageDirectoryCandidates(for: sourceTemplate).count

        for index in 0..<candidateCount {
            let caseDir = tempDir.appendingPathComponent("Candidate-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: caseDir, withIntermediateDirectories: true)
            let source = caseDir.appendingPathComponent("Model.sqlite")
            try writeDatabaseFileSet(at: source, marker: "candidate-\(index)", supportDirectoryIndex: index)

            let backupDir = caseDir.appendingPathComponent("Backups", isDirectory: true)
            guard let backup = DatabaseRecoveryService.shared.createBackup(of: source, in: backupDir) else {
                XCTFail("Expected backup for external storage candidate \(index)")
                continue
            }
            XCTAssertEqual(
                try String(contentsOf: supportBlobURL(for: backup, supportDirectoryIndex: index)),
                "candidate-\(index)-external-blob"
            )

            let restored = caseDir.appendingPathComponent("Restored.sqlite")
            XCTAssertTrue(DatabaseRecoveryService.shared.restoreFromBackup(backupURL: backup, to: restored))
            XCTAssertEqual(
                try String(contentsOf: supportBlobURL(for: restored, supportDirectoryIndex: index)),
                "candidate-\(index)-external-blob"
            )

            DatabaseRecoveryService.shared.deleteCorruptedFiles(at: restored)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: supportDirectory(for: restored, supportDirectoryIndex: index).path),
                "support candidate \(index) should be removed"
            )
        }
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
        XCTAssertEqual(try String(contentsOf: supportBlobURL(for: newest)), "new-external-blob")
    }

    private func writeDatabaseFileSet(at sqliteURL: URL, marker: String, supportDirectoryIndex: Int = 0) throws {
        try marker.write(to: sqliteURL, atomically: true, encoding: .utf8)
        for ext in DatabaseRecoveryService.sqliteSidecarExtensions {
            try "\(marker)-\(ext)".write(
                to: sidecarURL(for: sqliteURL, ext: ext),
                atomically: true,
                encoding: .utf8
            )
        }
        let externalDataDir = supportDirectory(for: sqliteURL, supportDirectoryIndex: supportDirectoryIndex)
            .appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDataDir, withIntermediateDirectories: true)
        try "\(marker)-external-blob".write(
            to: externalDataDir.appendingPathComponent("blob"),
            atomically: true,
            encoding: .utf8
        )
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
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: supportBlobURL(for: sqliteURL).path),
            "external binary storage support directory should exist",
            file: file,
            line: line
        )
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
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: supportDirectory(for: sqliteURL).path),
            "external binary storage support directory should be removed",
            file: file,
            line: line
        )
    }

    private func sidecarURL(for sqliteURL: URL, ext: String) -> URL {
        sqliteURL.deletingPathExtension().appendingPathExtension(ext)
    }

    private func supportDirectory(for sqliteURL: URL) -> URL {
        supportDirectory(for: sqliteURL, supportDirectoryIndex: 0)
    }

    private func supportDirectory(for sqliteURL: URL, supportDirectoryIndex: Int) -> URL {
        DatabaseRecoveryService.externalStorageDirectoryCandidates(for: sqliteURL)[supportDirectoryIndex]
    }

    private func supportBlobURL(for sqliteURL: URL) -> URL {
        supportBlobURL(for: sqliteURL, supportDirectoryIndex: 0)
    }

    private func supportBlobURL(for sqliteURL: URL, supportDirectoryIndex: Int) -> URL {
        supportDirectory(for: sqliteURL, supportDirectoryIndex: supportDirectoryIndex)
            .appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
            .appendingPathComponent("blob")
    }

    private func setCreationDate(_ date: Date, for sqliteURL: URL) throws {
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: sqliteURL.path)
    }
}
