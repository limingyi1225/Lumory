import Foundation
import SwiftUI
import Combine

// MARK: - Public types

/// LLM 真正撰写出的一批文案。拿给 AskPastView 当预设问题、HomeView 当占位语池。
/// 两个字段必须都非空（起码一条）才算有效；任何一边空就走 fallback。
struct SuggestionBundle: Codable, Equatable {
    var askPastPresets: [String]      // 4 条完整自然句，结尾带问号
    var homePlaceholders: [String]    // 5 条短句（≤20 字），引起用户写作
    var generatedAt: Date
    var fingerprint: String           // 数据指纹——变了说明需要重新生成
    var language: String              // "zh" / "en"，由日记主语言决定

    var hasUsableContent: Bool {
        !askPastPresets.isEmpty && !homePlaceholders.isEmpty
    }
}

/// 喂给 LLM 的 grounding 数据。全部从 InsightsEngine 现有接口取，不自己造。
struct SuggestionContext {
    let topThemes: [InsightsEngine.Theme]
    let moodAvg30d: Double
    let moodHighEntry: DiaryEntryData?   // 30 天情绪最高那条
    let moodLowEntry: DiaryEntryData?    // 30 天情绪最低那条
    let currentStreak: Int
    let totalEntries: Int
    let recentEntries: [DiaryEntryData]  // 最近 3 条，text 已截 ≤200 字
    let language: String                 // "zh" / "en"

    /// 稳定指纹——输入变了则重新生成。取 top-3 主题名 + 总条数 + 最新日记那一天。
    func makeFingerprint() -> String {
        let topNames = topThemes.prefix(3).map { $0.name.lowercased() }.joined(separator: "|")
        let latestDay: String = {
            guard let latest = recentEntries.first else { return "none" }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: latest.date)
        }()
        return "\(language)|\(totalEntries)|\(latestDay)|\(topNames)"
    }

    /// 数据太少时跳 AI，让调用方落到模板 fallback。
    var hasEnoughSignal: Bool {
        totalEntries >= 3
    }
}

// MARK: - Engine

/// 在 App 里只存一份。内存里保留当前 bundle；AppStorage 持久化。
@MainActor
final class PromptSuggestionEngine: ObservableObject {
    static let shared = PromptSuggestionEngine()

    // MARK: Published state

    @Published private(set) var current: SuggestionBundle?
    @Published private(set) var isRefreshing: Bool = false

    // MARK: Dependencies

    private let insights: InsightsEngine
    private let ai: AIServiceProtocol
    // V2：去掉 prompt 里的日期锚点后 bump；老 cache 里可能还有 "三天前/1-10 号" 这种 date-anchored
    // 问题，下次启动时 loadCache 找不到 V2 → 走新 prompt 重新生成。老的 V1 文件留在磁盘占几 KB，
    // 可接受；真要清可以 scan applicationSupport 里的 `.protected.json` 清一次，但没必要。
    private let cacheKey = "promptSuggestionCacheV2"
    private let ttl: TimeInterval = 24 * 60 * 60   // 24 小时

    /// 随机池选中后记录，避免连续重复
    private var lastPlaceholderIndex: Int?
    /// Bool 语义：true = AI 真的生成并写入新 bundle；false = 跳过（信号不足）或失败。
    /// "一键重建" 里会再拿日记总数兜底判断 false 是不是因为 <3 条，避免误报失败。
    private var inFlight: Task<Bool, Never>?

    init(
        insights: InsightsEngine = .shared,
        ai: AIServiceProtocol = OpenAIService(apiKey: "")
    ) {
        self.insights = insights
        self.ai = ai
        self.current = Self.loadCache(key: cacheKey)
    }

    // MARK: Public API

    /// AskPastView / HomeView 进入时调。会用指纹判断是否需要重新生成；
    /// 如果缓存还新鲜就直接 return，不发网络请求。
    func refreshIfNeeded() async {
        if let bundle = current, Self.isFresh(bundle: bundle, ttl: ttl) {
            // fingerprint 变化的二次检查：必要时再刷
            if await fingerprintMatchesCurrentData(bundle) { return }
        }
        _ = await runRefresh()
    }

    /// 用户点 refresh 按钮时强制刷新。
    /// 返回值：`true` 表示真的生成了新 bundle 并写入 cache；`false` 表示跳过或失败
    /// （信号不足 / AI 没返回有效内容 / 网错 / bundle 内容为空）。调用方可据此判定
    /// "一键重建" 流程是真成功还是仅 fall back 到旧 cache。
    @discardableResult
    func forceRefresh() async -> Bool {
        await runRefresh()
    }

    /// 从 homePlaceholders 池里随机挑一条；避免连续重复。
    /// 池空返回 nil，调用方自行 fallback。
    func randomHomePlaceholder() -> String? {
        guard let pool = current?.homePlaceholders, !pool.isEmpty else { return nil }
        if pool.count == 1 { return pool[0] }
        var idx = Int.random(in: 0..<pool.count)
        // 避免连续两次一样
        if idx == lastPlaceholderIndex {
            idx = (idx + 1) % pool.count
        }
        lastPlaceholderIndex = idx
        return pool[idx]
    }

    // MARK: Core refresh

    private func runRefresh() async -> Bool {
        if let task = inFlight {
            return await task.value
        }
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self.executeRefresh()
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func executeRefresh() async -> Bool {
        isRefreshing = true
        defer { isRefreshing = false }

        let context = await buildContext()
        guard context.hasEnoughSignal else {
            Log.info("[PromptSuggestion] signal 不够（<3 条），跳过 AI", category: .ai)
            return false
        }

        guard let bundle = await ai.composeSuggestions(context: context) else {
            Log.error("[PromptSuggestion] AI 未返回有效 bundle，保留旧 cache", category: .ai)
            return false
        }
        guard bundle.hasUsableContent else {
            Log.error("[PromptSuggestion] bundle 字段空，保留旧 cache", category: .ai)
            return false
        }

        current = bundle
        Self.saveCache(bundle: bundle, key: cacheKey)
        Log.info("[PromptSuggestion] 新 bundle 生成并缓存：\(bundle.askPastPresets.count) presets / \(bundle.homePlaceholders.count) placeholders", category: .ai)
        return true
    }

    // MARK: Context building

    private func buildContext() async -> SuggestionContext {
        let now = Date()
        let calendar = Calendar.current
        let themeRange = DateInterval(
            start: calendar.date(byAdding: .day, value: -90, to: now) ?? now,
            end: now
        )
        let moodRange = DateInterval(
            start: calendar.date(byAdding: .day, value: -30, to: now) ?? now,
            end: now
        )

        async let themes = insights.themes(in: themeRange, limit: 5)
        async let stats = insights.writingStats()
        async let recent = insights.recentEntries(limit: 3, textCharCap: 200)
        async let extremes = insights.moodExtremes(in: moodRange)
        async let moodPoints = insights.moodSeries(in: moodRange, bucket: .day)

        let (topThemes, writingStats, recentEntries, moodExtremes, mpoints) =
            await (themes, stats, recent, extremes, moodPoints)

        let moodAvg = mpoints.isEmpty ? 0.5 : mpoints.reduce(0.0) { $0 + $1.mood } / Double(mpoints.count)
        let language = Self.detectLanguage(from: recentEntries)

        return SuggestionContext(
            topThemes: topThemes,
            moodAvg30d: moodAvg,
            moodHighEntry: moodExtremes.high,
            moodLowEntry: moodExtremes.low,
            currentStreak: writingStats.currentStreak,
            totalEntries: writingStats.totalEntries,
            recentEntries: recentEntries,
            language: language
        )
    }

    private func fingerprintMatchesCurrentData(_ bundle: SuggestionBundle) async -> Bool {
        let ctx = await buildContext()
        return ctx.makeFingerprint() == bundle.fingerprint
    }

    // MARK: Cache

    /// 判断缓存是否在 TTL 内。`now` 参数让单测不依赖当前时间。
    /// `nonisolated` —— 外层 class 是 @MainActor，但这是纯函数没有 actor 状态，
    /// 不隔离才能让 `ChronoteTests` 的非 MainActor 上下文直接调。
    nonisolated static func isFresh(bundle: SuggestionBundle, ttl: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(bundle.generatedAt) < ttl
    }

    /// 把 SuggestionBundle 存到 Application Support 下的 `.protected` 文件，并加 `.completeUnlessOpen`
    /// file protection——这份 bundle 里含用户日记派生的 prompt（指向 Abby / 工作 / 某天某事），
    /// 以前放在 UserDefaults 里明文，越狱 / sysdiagnose / 第三方备份都能读。file protection 能保证
    /// 设备锁定后的磁盘镜像里是加密的。
    private static func cacheFileURL(key: String) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("\(key).protected.json")
    }

    private static func loadCache(key: String) -> SuggestionBundle? {
        if let url = cacheFileURL(key: key),
           let data = try? Data(contentsOf: url),
           let bundle = try? JSONDecoder().decode(SuggestionBundle.self, from: data) {
            return bundle
        }
        // 兼容老版本：UserDefaults 里的旧 cache 还在就一次性迁移走
        if let legacy = UserDefaults.standard.data(forKey: key) {
            if let bundle = try? JSONDecoder().decode(SuggestionBundle.self, from: legacy) {
                saveCache(bundle: bundle, key: key)
                UserDefaults.standard.removeObject(forKey: key)
                return bundle
            }
            UserDefaults.standard.removeObject(forKey: key)
        }
        return nil
    }

    private static func saveCache(bundle: SuggestionBundle, key: String) {
        guard let data = try? JSONEncoder().encode(bundle), let url = cacheFileURL(key: key) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            Log.error("[PromptSuggestion] cache 写失败：\(error)", category: .ai)
        }
    }

    // MARK: Helpers

    /// 简单语言检测：数最近 3 条日记里的 CJK 字符比例 > 30% 则视作中文。
    private static func detectLanguage(from entries: [DiaryEntryData]) -> String {
        let joined = entries.map { $0.text }.joined()
        guard !joined.isEmpty else {
            return Locale.current.identifier.hasPrefix("zh") ? "zh" : "en"
        }
        var cjkCount = 0
        for scalar in joined.unicodeScalars {
            // 覆盖常用 CJK + 扩展 A + 标点
            if (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value) {
                cjkCount += 1
            }
        }
        return Double(cjkCount) / Double(joined.unicodeScalars.count) > 0.3 ? "zh" : "en"
    }
}
