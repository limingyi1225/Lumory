import Foundation

/// Widget 与主 App 之间的共享数据契约。
///
/// **不含日记正文** —— V1 schema 曾经有 `lastEntryDisplayText` / Snippet.displayText 字段,
/// 配合 `lumory.widget.showSnippets` toggle 把日记片段写到 App Group 磁盘。后来发现把 PII 写到
/// 主屏可见处性价比低 + on/off 切换有 250ms debounce 边角竞争,V2 schema 一刀切掉所有正文。
/// 一度还有 `recentDays: [DayMood]`(14 天 mood 条带),实际渲染太杂被 V3 视图删了。一并砍掉。
///
/// 设计要点:
/// 1. **streak 由主 App 算好存进来**(currentStreak / longestStreak)。widget 端**不**复算 ——
///    避免复制 `InsightsEngine.computeStreaks` 实现到 widget 跟主 App drift。
///    widget 只用 `WidgetTodayContext` 做"今日是否仍有效"轻量判断。
/// 2. **`lastEntryMood`** 只用作"今日心情"展示 —— 但视图层有 `wroteToday` guard,
///    没写过今天就不画 mood,不会拿"昨天的 mood"冒充今日。
/// 3. **`prompt`** 由主 App 端 `PromptSuggestionEngine.randomHomePlaceholder()` 取一次写进来,
///    widget 不调 AI / 不读 PromptSuggestionEngine。每次主 App snapshot refresh 时换一句。
///    "今日未写"时 widget 用它做大字 headline;写过了 headline 走状态文字。
/// 4. `schemaVersion` 给 future migration 用,V2 = 2。读到不认识版本 → 让调用方走 empty 兜底。
///    旧 V1 / 中间形态(带 recentDays)的文件被严格 schemaVersion guard 拒收 → empty → 主 App
///    再写入,自然 self-heal。
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date

    public var currentStreak: Int
    public var longestStreak: Int

    public var lastEntryDate: Date?
    public var lastEntryMood: Double?

    /// 写作 prompt。仅"今日未写"时 widget 当 headline 展示。
    /// 可能 nil(prompt cache 空 —— 比如 fresh install 还没拉过 AI bundle)→ headline fallback CTA。
    public var prompt: String?

    public init(
        schemaVersion: Int = 2,
        generatedAt: Date,
        currentStreak: Int,
        longestStreak: Int,
        lastEntryDate: Date?,
        lastEntryMood: Double?,
        prompt: String?
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.lastEntryDate = lastEntryDate
        self.lastEntryMood = lastEntryMood
        self.prompt = prompt
    }

    /// 没数据 / 用户全删 / store 加载失败 时的安全占位。clear() 写入这个值
    /// 而不是删文件 —— 让 widget 能稳定渲染 fallback CTA,而不是退回 placeholder。
    public static func empty(now: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: now,
            currentStreak: 0,
            longestStreak: 0,
            lastEntryDate: nil,
            lastEntryMood: nil,
            prompt: nil
        )
    }
}
