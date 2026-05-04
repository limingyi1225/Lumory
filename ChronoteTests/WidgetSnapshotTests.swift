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
            totalEntries: 42,
            totalWords: 12345,
            currentStreak: 7,
            longestStreak: 30,
            lastEntryDate: now,
            lastEntryMood: 0.6,
            lastEntryDisplayText: "今天很好",
            recent: [
                WidgetSnapshot.Snippet(id: UUID(), date: now, moodValue: 0.5, displayText: "片段")
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(decoded.totalEntries, 42)
        XCTAssertEqual(decoded.totalWords, 12345)
        XCTAssertEqual(decoded.currentStreak, 7)
        XCTAssertEqual(decoded.longestStreak, 30)
        XCTAssertEqual(decoded.lastEntryDisplayText, "今天很好")
        XCTAssertEqual(decoded.recent.count, 1)
    }

    // MARK: - Store IO

    func testWriteThenRead() throws {
        let snap = WidgetSnapshot(
            generatedAt: Date(),
            totalEntries: 5,
            totalWords: 100,
            currentStreak: 2,
            longestStreak: 5,
            lastEntryDate: Date(),
            lastEntryMood: 0.7,
            lastEntryDisplayText: nil,
            recent: []
        )
        try WidgetSnapshotStore.write(snap)
        let loaded = WidgetSnapshotStore.read()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.totalEntries, 5)
        XCTAssertEqual(loaded?.totalWords, 100)
        XCTAssertEqual(loaded?.currentStreak, 2)
    }

    func testReadReturnsNilWhenFileMissing() {
        XCTAssertNil(WidgetSnapshotStore.read())
    }

    func testClearWritesEmptySnapshotInsteadOfDeleting() throws {
        let snap = WidgetSnapshot(
            generatedAt: Date(),
            totalEntries: 3,
            totalWords: 50,
            currentStreak: 1,
            longestStreak: 1,
            lastEntryDate: Date(),
            lastEntryMood: 0.5,
            lastEntryDisplayText: nil,
            recent: []
        )
        try WidgetSnapshotStore.write(snap)
        WidgetSnapshotStore.clear()
        let loaded = WidgetSnapshotStore.read()
        XCTAssertNotNil(loaded, "clear() should leave an empty snapshot file, not delete it")
        XCTAssertEqual(loaded?.totalEntries, 0)
        XCTAssertEqual(loaded?.currentStreak, 0)
        XCTAssertTrue(loaded?.recent.isEmpty ?? false)
    }

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

    func testWrittenJSONOmitsTextFieldsWhenNil() throws {
        let snap = WidgetSnapshot(
            generatedAt: Date(),
            totalEntries: 1,
            totalWords: 10,
            currentStreak: 1,
            longestStreak: 1,
            lastEntryDate: Date(),
            lastEntryMood: 0.5,
            lastEntryDisplayText: nil,  // toggle off 时
            recent: [
                WidgetSnapshot.Snippet(id: UUID(), date: Date(), moodValue: 0.5, displayText: nil)
            ]
        )
        try WidgetSnapshotStore.write(snap)
        guard let url = WidgetSnapshotStore.snapshotURL(),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("snapshot file missing")
            return
        }
        // **不要求** "displayText": null —— Swift Codable 默认 omit nil。
        // 验证标准是文件里**不出现**真实正文字符串。这里我们传的就是 nil,所以正文字符串 0 出现。
        XCTAssertFalse(raw.contains("\"displayText\":\"") && !raw.contains("\"displayText\":null"),
                       "Should not contain non-null displayText payload")
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

    // MARK: - Helpers

    private func makeSnap(currentStreak: Int, lastEntryDate: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: Date(),
            totalEntries: 10,
            totalWords: 100,
            currentStreak: currentStreak,
            longestStreak: currentStreak,
            lastEntryDate: lastEntryDate,
            lastEntryMood: 0.5,
            lastEntryDisplayText: nil,
            recent: []
        )
    }
}
