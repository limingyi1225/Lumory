import Foundation

/// Widget 与主 App 之间的共享数据契约。
///
/// 设计要点:
/// 1. **streak 由主 App 算好存进来**(currentStreak / longestStreak)。widget 端**不**复算 —— 一是避免
///    复制 `InsightsEngine.computeStreaks` 实现到 widget 跟主 App drift;二是要算 200+ 天连续
///    需要在 widget 里塞下完整 unique-day 列表,不划算。widget 只做"今日是否仍有效"的轻量判断。
/// 2. **`displayText` 系列字段是 PII**(日记正文片段)。仅当用户在 Settings 翻开
///    `lumory.widget.showSnippets` 才填,off 时不写到磁盘。toggle off→on 翻转后下次
///    snapshot refresh 才会出现;翻 off 时立即 scrub(见 `WidgetSnapshotService`)。
/// 3. `schemaVersion` 给 future migration 用,V1 = 1。读到不认识版本 → 回 nil 让 widget 走 empty 态。
public struct WidgetSnapshot: Codable, Equatable {
    public var schemaVersion: Int
    public var generatedAt: Date

    public var totalEntries: Int
    public var totalWords: Int
    public var currentStreak: Int
    public var longestStreak: Int

    public var lastEntryDate: Date?
    public var lastEntryMood: Double?
    public var lastEntryDisplayText: String?

    public var recent: [Snippet]

    public struct Snippet: Codable, Equatable, Identifiable {
        public var id: UUID
        public var date: Date
        public var moodValue: Double
        public var displayText: String?

        public init(id: UUID, date: Date, moodValue: Double, displayText: String?) {
            self.id = id
            self.date = date
            self.moodValue = moodValue
            self.displayText = displayText
        }
    }

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date,
        totalEntries: Int,
        totalWords: Int,
        currentStreak: Int,
        longestStreak: Int,
        lastEntryDate: Date?,
        lastEntryMood: Double?,
        lastEntryDisplayText: String?,
        recent: [Snippet]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.totalEntries = totalEntries
        self.totalWords = totalWords
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.lastEntryDate = lastEntryDate
        self.lastEntryMood = lastEntryMood
        self.lastEntryDisplayText = lastEntryDisplayText
        self.recent = recent
    }

    /// 没数据 / 用户全删 / store 加载失败 时的安全占位。clear() 写入这个值
    /// 而不是删文件 —— 让 widget 能稳定渲染"暂无日记",不退回 placeholder 的错觉。
    public static func empty(now: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: now,
            totalEntries: 0,
            totalWords: 0,
            currentStreak: 0,
            longestStreak: 0,
            lastEntryDate: nil,
            lastEntryMood: nil,
            lastEntryDisplayText: nil,
            recent: []
        )
    }
}
