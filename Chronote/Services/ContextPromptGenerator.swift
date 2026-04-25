import Foundation
import CoreData

// MARK: - ContextPromptGenerator
//
// 根据最近 3-7 天的日记主题 + 当前时间生成一条写作起手语。
// 本地生成，不依赖 AI —— 保证键盘拉起时 0 延迟；若以后接入 AI，也只需在这一层替换。
//
// Phase 3.1 · 上下文提示。

struct ContextPrompt: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

@available(iOS 15.0, macOS 12.0, *)
final class ContextPromptGenerator {
    static let shared = ContextPromptGenerator()

    private let persistence: PersistenceController
    private let recentDays: Int
    private let lapseDays: Int   // 多少天没写某主题算"消失"

    init(persistence: PersistenceController = .shared, recentDays: Int = 7, lapseDays: Int = 5) {
        self.persistence = persistence
        self.recentDays = recentDays
        self.lapseDays = lapseDays
    }

    // MARK: - Public API

    /// 返回一组（0-3 条）候选提示，UI 层可以展示一条 + "换一条"。
    func generate() async -> [ContextPrompt] {
        let now = Date()
        let calendar = Calendar.current
        let recentStart = calendar.date(byAdding: .day, value: -recentDays, to: now) ?? now
        let lapseStart = calendar.date(byAdding: .day, value: -30, to: now) ?? now

        let (recentEntries, olderEntries) = await fetchEntries(recentStart: recentStart, lapseStart: lapseStart)

        var prompts: [ContextPrompt] = []

        // 1. 昨天写的主题 → "昨天你提到『X』，今天感觉如何？"
        if let yesterday = yesterdayPrompt(recentEntries: recentEntries, calendar: calendar, now: now) {
            prompts.append(yesterday)
        }

        // 2. 主题消失 → "你已经 3 天没写『家人』了"
        if let lapse = lapsePrompt(recentEntries: recentEntries, olderEntries: olderEntries, calendar: calendar, now: now) {
            prompts.append(lapse)
        }

        // 3. 情绪波动 → "最近情绪有点起伏，想聊聊吗？"
        if let moodSwing = moodSwingPrompt(recentEntries: recentEntries) {
            prompts.append(moodSwing)
        }

        // 4. 最常写到的主题（任何时候都能出，真正和用户相关）
        if let topTheme = topThemePrompt(recentEntries: recentEntries, olderEntries: olderEntries) {
            prompts.append(topTheme)
        }

        // 5. 兜底：连续天数 → 时间段问候（更泛）
        if let streakHint = streakPrompt(recentEntries: recentEntries, calendar: calendar, now: now) {
            prompts.append(streakHint)
        }
        prompts.append(timeOfDayPrompt(now: now))

        // 至少一条 blank 兜底
        if prompts.isEmpty {
            prompts.append(ContextPrompt(text: NSLocalizedString("今天发生了什么？", comment: "Blank prompt")))
        }

        return prompts
    }

    // MARK: - Individual strategies

    private func yesterdayPrompt(recentEntries: [Snapshot], calendar: Calendar, now: Date) -> ContextPrompt? {
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        let yesterdayEnd = calendar.startOfDay(for: now)
        let yesterdayEntries = recentEntries.filter { $0.date >= yesterdayStart && $0.date < yesterdayEnd }
        let themes = yesterdayEntries.flatMap { $0.themes }
        // 挑一个有辨识度的主题（不是"情绪"这种太泛的）
        let goodThemes = themes.filter { $0 != NSLocalizedString("情绪", comment: "") }
        guard let theme = goodThemes.first else { return nil }
        return ContextPrompt(text: String(format: NSLocalizedString("昨天你提到 %@，今天感觉如何？", comment: "Yesterday theme follow-up"), theme))
    }

    private func lapsePrompt(recentEntries: [Snapshot], olderEntries: [Snapshot], calendar: Calendar, now: Date) -> ContextPrompt? {
        let olderThemes = Set(olderEntries.flatMap { $0.themes })
        let recentThemes = Set(recentEntries.flatMap { $0.themes })
        let lapsed = olderThemes.subtracting(recentThemes)
        guard let theme = lapsed.first(where: { !$0.isEmpty }) else { return nil }

        // 找出该主题最近一次出现，计算间隔
        guard let lastSeen = olderEntries
            .filter({ $0.themes.contains(theme) })
            .map({ $0.date })
            .max() else { return nil }
        let days = calendar.dateComponents([.day], from: lastSeen, to: now).day ?? 0
        guard days >= lapseDays else { return nil }

        return ContextPrompt(text: String(format: NSLocalizedString("已经 %d 天没提到 %@ 了，最近怎么样？", comment: "Theme lapse"), days, theme))
    }

    /// 从日记里"长出来"的人/物/事 prompt：扫描 recent + older 的 themes，
    /// 按「出现在几个不同的天」排序——比原生 frequency 更能浮现反复出现的人物/项目，
    /// 比如 Abby 出现在 8 个不同的日子比"工作"出现在 3 天 × 若干篇更"主角"。
    /// 元描述（情绪/日常 等）由 InsightsEngine.isBannedTheme 在源头挡掉。
    private func topThemePrompt(recentEntries: [Snapshot], olderEntries: [Snapshot]) -> ContextPrompt? {
        let all = recentEntries + olderEntries
        let calendar = Calendar.current

        var daysByTheme: [String: Set<Date>] = [:]
        var totalCount: [String: Int] = [:]
        for entry in all {
            let day = calendar.startOfDay(for: entry.date)
            for theme in entry.themes where !theme.isEmpty && !InsightsEngine.isBannedTheme(theme) {
                daysByTheme[theme, default: []].insert(day)
                totalCount[theme, default: 0] += 1
            }
        }

        // 按出现的独立天数排序；tie-break 用总次数
        let ranked = daysByTheme
            .filter { $0.value.count >= 2 }  // 至少两天出现过才算"反复"
            .sorted {
                if $0.value.count != $1.value.count {
                    return $0.value.count > $1.value.count
                }
                return (totalCount[$0.key] ?? 0) > (totalCount[$1.key] ?? 0)
            }
        guard let (theme, _) = ranked.first else { return nil }

        let templates = [
            NSLocalizedString("最近 %@ 怎么样？", comment: "Top theme template 1"),
            NSLocalizedString("今天想到 %@ 了吗？", comment: "Top theme template 2"),
            NSLocalizedString("%@ 最近给你带来什么？", comment: "Top theme template 3")
        ]
        // `String.hashValue` Swift 5.7+ 每个进程随机化（防 hash flooding）——同一 theme
        // 每次冷启动落到不同模板上，"稳定模板/主题"意图就破了。改用 FNV-1a 32-bit 拿
        // 进程无关的确定性 hash。
        let idx = Int(Self.stableHash(theme) % UInt32(templates.count))
        return ContextPrompt(text: String(format: templates[idx], theme))
    }

    private func moodSwingPrompt(recentEntries: [Snapshot]) -> ContextPrompt? {
        guard recentEntries.count >= 3 else { return nil }
        let moods = recentEntries.map { $0.moodValue }
        let range = (moods.max() ?? 0.5) - (moods.min() ?? 0.5)
        guard range >= 0.5 else { return nil }
        return ContextPrompt(text: NSLocalizedString("最近几天情绪有点起伏，现在的你怎么样？", comment: "Mood swing"))
    }

    private func timeOfDayPrompt(now: Date) -> ContextPrompt {
        let hour = Calendar.current.component(.hour, from: now)
        let text: String
        switch hour {
        case 5..<11:
            text = NSLocalizedString("早上好，今天想做点什么？", comment: "Morning prompt")
        case 11..<14:
            text = NSLocalizedString("午安，上午过得怎么样？", comment: "Noon prompt")
        case 14..<18:
            text = NSLocalizedString("下午状态如何？", comment: "Afternoon prompt")
        case 18..<23:
            text = NSLocalizedString("今晚想记录什么？", comment: "Evening prompt")
        default:
            text = NSLocalizedString("夜深了，今天最触动你的一件事是？", comment: "Late night prompt")
        }
        return ContextPrompt(text: text)
    }

    private func streakPrompt(recentEntries: [Snapshot], calendar: Calendar, now: Date) -> ContextPrompt? {
        let streak = Self.computeStreak(entryDates: recentEntries.map { $0.date }, calendar: calendar, now: now)
        guard streak >= 3 else { return nil }
        return ContextPrompt(text: String(format: NSLocalizedString("已经连续 %d 天了，今天也写几笔吧", comment: "Streak prompt"), streak))
    }

    /// 计算 streak。**从 today 或 yesterday 起步**：以前 cursor 固定从 today 开始，
    /// 如果用户连写 5 天但还没动笔记录今天，uniqueDays 不含 today，整个循环 0 次，streak=0，
    /// 连续书写提示被直接吞掉。对齐 InsightsEngine.computeStreaks 的口径：today 在就从 today，
    /// today 不在但 yesterday 在就从 yesterday，这样"活跃中但今天还没写"的 case 也能拿到提示。
    ///
    /// `static` + `internal`：让单元测试不依赖 private Snapshot、不进整条 fetch/prompt 管道就能覆盖到边界。
    static func computeStreak(entryDates: [Date], calendar: Calendar, now: Date) -> Int {
        let today = calendar.startOfDay(for: now)
        let uniqueDays = Set(entryDates.map { calendar.startOfDay(for: $0) })
        var cursor = today
        if !uniqueDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  uniqueDays.contains(yesterday) else {
                return 0
            }
            cursor = yesterday
        }
        var streak = 0
        while uniqueDays.contains(cursor) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    /// FNV-1a 32-bit hash. 进程无关、确定性——用来给同一 theme 永远选到同一条模板，
    /// 替代 Swift 标准库被随机化的 `String.hashValue`。
    static func stableHash(_ string: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in string.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash
    }

    // MARK: - Data

    private struct Snapshot {
        let date: Date
        let themes: [String]
        let moodValue: Double
    }

    private func fetchEntries(recentStart: Date, lapseStart: Date) async -> (recent: [Snapshot], older: [Snapshot]) {
        await persistence.container.performBackgroundTask { context in
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.predicate = NSPredicate(format: "date >= %@", lapseStart as NSDate)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
            guard let entries = try? context.fetch(request) else { return ([], []) }
            var recent: [Snapshot] = []
            var older: [Snapshot] = []
            for entry in entries {
                let date = entry.date ?? Date.distantPast
                let snap = Snapshot(date: date, themes: entry.themeArray, moodValue: entry.moodValue)
                if date >= recentStart {
                    recent.append(snap)
                } else {
                    older.append(snap)
                }
            }
            return (recent, older)
        }
    }
}
