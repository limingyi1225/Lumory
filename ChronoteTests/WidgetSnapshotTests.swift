import XCTest
@testable import Lumory

/// `WidgetSnapshot` Codable round-trip + `WidgetSnapshotStore` write/read/clear +
/// `WidgetTodayContext` 跨午夜翻状态。
///
/// **测试串行**:`WidgetSnapshotStore.overrideURL` 是 mutable 全局,XCTestCase 默认串行
/// 已满足要求。每个 test 在 `setUp` set unique temp dir,`tearDown` 清回 nil + 删 dir。
/// 若 future migrate 到 Swift Testing,需要加 `@Suite(.serialized)`。
final class WidgetSnapshotTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WidgetSnapshotTests-\(UUID().uuidString)"
        )
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        WidgetSnapshotStore.overrideURL = tempDir.appendingPathComponent("snapshot.json")
    }

    override func tearDown() {
        WidgetSnapshotStore.overrideURL = nil
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let now = Date()
        let original = WidgetSnapshot(
            generatedAt: now,
            currentStreak: 7,
            longestStreak: 30,
            lastEntryDate: now,
            lastEntryMood: 0.6,
            prompt: "今天最让你期待的是什么?"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(decoded.currentStreak, 7)
        XCTAssertEqual(decoded.longestStreak, 30)
        XCTAssertEqual(decoded.lastEntryMood, 0.6)
        XCTAssertEqual(decoded.prompt, "今天最让你期待的是什么?")
        XCTAssertEqual(decoded.schemaVersion, 2)
    }

    // MARK: - Store IO

    func testWriteThenRead() throws {
        let snap = WidgetSnapshot(
            generatedAt: Date(),
            currentStreak: 2,
            longestStreak: 5,
            lastEntryDate: Date(),
            lastEntryMood: 0.7,
            prompt: nil
        )
        try WidgetSnapshotStore.write(snap)
        let loaded = WidgetSnapshotStore.read()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.currentStreak, 2)
        XCTAssertEqual(loaded?.longestStreak, 5)
    }

    func testReadReturnsNilWhenFileMissing() {
        XCTAssertNil(WidgetSnapshotStore.read())
    }

    func testClearWritesEmptySnapshotInsteadOfDeleting() throws {
        let snap = WidgetSnapshot(
            generatedAt: Date(),
            currentStreak: 1,
            longestStreak: 1,
            lastEntryDate: Date(),
            lastEntryMood: 0.5,
            prompt: "测试 prompt"
        )
        try WidgetSnapshotStore.write(snap)
        WidgetSnapshotStore.clear()
        let loaded = WidgetSnapshotStore.read()
        XCTAssertNotNil(loaded, "clear() should leave an empty snapshot file, not delete it")
        XCTAssertEqual(loaded?.currentStreak, 0)
        XCTAssertEqual(loaded?.longestStreak, 0)
        XCTAssertNil(loaded?.prompt)
    }

    #if DEBUG
    func testFetchFailureKeepsPreviousSnapshotFile() async throws {
        let previous = WidgetSnapshot(
            generatedAt: Date(),
            currentStreak: 4,
            longestStreak: 9,
            lastEntryDate: Date(),
            lastEntryMood: 0.8,
            prompt: "previous prompt"
        )
        try WidgetSnapshotStore.write(previous)

        await WidgetSnapshotService.shared.refreshForTesting {
            nil
        }

        let loaded = WidgetSnapshotStore.read()
        XCTAssertEqual(loaded?.currentStreak, 4)
        XCTAssertEqual(loaded?.longestStreak, 9)
        XCTAssertEqual(loaded?.lastEntryMood, 0.8)
        XCTAssertEqual(loaded?.prompt, "previous prompt")
    }
    #endif

    func testBackupExclusion() throws {
        let snap = WidgetSnapshot.empty()
        try WidgetSnapshotStore.write(snap)
        guard let url = WidgetSnapshotStore.snapshotURL() else {
            XCTFail("snapshotURL nil under override")
            return
        }
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    /// V1 (showSnippets era) snapshots had different fields. The Decoder will succeed because
    /// the JSON happens to contain all V2-required fields (V2 optional fields are nil-coalescing),
    /// so the schemaVersion guard is what does the rejection — verify both that the decode
    /// succeeds AND that the guard returns nil.
    func testV1JSONDecodesButGuardCatches() throws {
        let v1JSON = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-01-01T00:00:00Z",
          "totalEntries": 5,
          "totalWords": 100,
          "currentStreak": 1,
          "longestStreak": 1,
          "lastEntryDate": "2026-01-01T00:00:00Z",
          "lastEntryMood": 0.5,
          "lastEntryDisplayText": "stale text",
          "recent": []
        }
        """.data(using: .utf8)!

        // Decoder side: succeeds, schemaVersion comes through as 1
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: v1JSON)
        XCTAssertEqual(decoded.schemaVersion, 1, "Decoder reads V1 fine; rejection happens at the schema guard, not at decode")

        // Store side: guard rejects because schemaVersion != 2
        guard let url = WidgetSnapshotStore.snapshotURL() else {
            XCTFail("snapshotURL nil under override"); return
        }
        try v1JSON.write(to: url)
        XCTAssertNil(WidgetSnapshotStore.read(),
                     "V1 schema must be rejected so widget falls back to .empty()")
    }

    /// Future-proof: schemaVersion 0 / 3 / 99 (corrupted, downgrade-from-future, garbage) all
    /// must be rejected. Locks the guard against accidental relaxation to `>= 2` or similar.
    func testNonV2SchemaVersionsAllRejected() throws {
        guard let url = WidgetSnapshotStore.snapshotURL() else {
            XCTFail("snapshotURL nil under override"); return
        }
        for version in [0, 3, 99] {
            let json = """
            {
              "schemaVersion": \(version),
              "generatedAt": "2026-01-01T00:00:00Z",
              "currentStreak": 1,
              "longestStreak": 1
            }
            """.data(using: .utf8)!
            try json.write(to: url)
            XCTAssertNil(
                WidgetSnapshotStore.read(),
                "schemaVersion=\(version) must be rejected — only V2 is the current contract"
            )
        }
    }

    // MARK: - WidgetTodayContext

    func testTodayContext_writtenToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let asOf = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 12))!
        let lastEntry = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 10))!

        let snap = makeSnap(currentStreak: 7, lastEntryDate: lastEntry)
        let ctx = WidgetTodayContext.compute(snapshot: snap, asOf: asOf, calendar: calendar)
        XCTAssertTrue(ctx.wroteToday)
        XCTAssertEqual(ctx.effectiveStreak, 7)
    }

    func testTodayContext_yesterdayStillCountsStreak() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let asOf = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 12))!
        let lastEntry = calendar.date(from: DateComponents(year: 2026, month: 5, day: 3, hour: 22))!

        let snap = makeSnap(currentStreak: 7, lastEntryDate: lastEntry)
        let ctx = WidgetTodayContext.compute(snapshot: snap, asOf: asOf, calendar: calendar)
        XCTAssertFalse(ctx.wroteToday)
        XCTAssertEqual(ctx.effectiveStreak, 7,
                       "yesterday written: streak still in flight (跟 InsightsEngine 同语义)")
    }

    func testTodayContext_twoDaysAgoBreaksStreak() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let asOf = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 12))!
        let lastEntry = calendar.date(from: DateComponents(year: 2026, month: 5, day: 2, hour: 22))!

        let snap = makeSnap(currentStreak: 7, lastEntryDate: lastEntry)
        let ctx = WidgetTodayContext.compute(snapshot: snap, asOf: asOf, calendar: calendar)
        XCTAssertFalse(ctx.wroteToday)
        XCTAssertEqual(ctx.effectiveStreak, 0)
    }

    func testTodayContext_emptySnapshot() {
        let ctx = WidgetTodayContext.compute(snapshot: .empty(), asOf: Date())
        XCTAssertFalse(ctx.wroteToday)
        XCTAssertEqual(ctx.effectiveStreak, 0)
    }

    // MARK: - Empty snapshot

    func testEmptySnapshotDefaults() {
        let snap = WidgetSnapshot.empty()
        XCTAssertEqual(snap.currentStreak, 0)
        XCTAssertEqual(snap.longestStreak, 0)
        XCTAssertNil(snap.lastEntryDate)
        XCTAssertNil(snap.lastEntryMood)
        XCTAssertNil(snap.prompt)
        XCTAssertEqual(snap.schemaVersion, 2)
    }

    // MARK: - Helpers

    private func makeSnap(currentStreak: Int, lastEntryDate: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: Date(),
            currentStreak: currentStreak,
            longestStreak: currentStreak,
            lastEntryDate: lastEntryDate,
            lastEntryMood: 0.5,
            prompt: nil
        )
    }
}
