import Foundation

// MARK: - LumoryDateFormatters
//
// **P1-T10 收编**:5 处独立 DateFormatter 缓存(HomeView / DiaryEntryRow / DiaryPreviewView /
// DiaryDetailView / CitationEntryCard / 等)合并到这一处。
//
// `DateFormatter` 实例**线程安全 since iOS 7**,但创建有 ~1ms 开销。每次 row 重 diff 都 new 一个
// 在长 list 里是真热路径浪费(reviewer 在 DiaryEntryRow.swift:194-210 注释里也提过)。
//
// 这里所有 formatter 都是 module-level `let`,启动时一次性初始化,跨 view 共享。
// 如果以后要按用户语言动态切 formatter,加一层 computed property 拉 `Locale.current` 即可。

enum LumoryDateFormatters {
    /// "上午 9:30" / "9:30 AM" — DiaryEntryRow / HomeView 时间戳。
    static let timeShort: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// "5月3日" / "May 3" — Home timeline section header / DiaryDetail 顶部。
    static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    /// "周三" / "Wed" — Home timeline section header / Calendar weekday。
    static let weekdayShort: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEE")
        return f
    }()

    /// "周三" 完整 / "Wednesday" — DiaryDetailView hero。
    static let weekdayFull: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    /// "2026年5月3日 上午9:30" / "May 3, 2026 at 9:30 AM" — DiaryDetailView hero / DiaryPreview。
    static let fullDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// "2026-05-03" 数字日期 — Theme alias / 内部诊断。
    static let isoDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "5月3日 周三" / "May 3, Wed" — Insights chart tooltip / CitationEntryCard。
    static let monthDayWeekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd EEEEE")
        return f
    }()

    /// "5月" / "May" — WritingHeatmap month label header(短月份)。
    static let monthShort: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("LLL")
        return f
    }()

    /// "17:30" 24h 数字格式 — locale-independent。HomeTimelineCard / DiaryPreviewView 时间戳。
    static let twentyFourHourTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "2026年5月3日" / "May 3, 2026" — Date-only `.medium`。DiaryExportView 日期范围、CitationEntryCard。
    static let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// "2026年5月3日 上午9:30" / "May 3, 2026 at 9:30 AM" — `.long + .short`。DiaryExportService 导出头/正文。
    static let longDateShortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    /// `.long` date-only,按 `appLanguage` 锁定语言。DiaryDetailView hero 顶部。
    static func longDate(language: String) -> DateFormatter {
        cachedFormatter(key: "longDate-\(language)") {
            let f = DateFormatter()
            f.locale = Locale(identifier: language)
            f.dateStyle = .long
            f.timeStyle = .none
            return f
        }
    }

    // MARK: - Language-aware accessors
    //
    // 上面的 token 用 `Locale.current`(系统当前)— 用户在 App 内通过 `@AppStorage("appLanguage")`
    // 主动切语言时跟系统不一定一致。Home / Detail / EntryRow 这类 list cell 必须按 `appLanguage`
    // 显示 weekday / monthDay,不能跟系统 locale 走。下面这一组按 language 缓存,
    // SwiftUI body 反复 evaluate 时不会重建 formatter。

    private static let languageCacheLock = NSLock()
    private static var languageCache: [String: DateFormatter] = [:]

    private static func cachedFormatter(
        key: String,
        build: () -> DateFormatter
    ) -> DateFormatter {
        languageCacheLock.lock()
        defer { languageCacheLock.unlock() }
        if let cached = languageCache[key] { return cached }
        let formatter = build()
        languageCache[key] = formatter
        return formatter
    }

    /// "5月3日" / "May 3" 按 `appLanguage` 锁定语言。
    static func monthDay(language: String) -> DateFormatter {
        cachedFormatter(key: "monthDay-\(language)") {
            let f = DateFormatter()
            f.locale = Locale(identifier: language)
            f.setLocalizedDateFormatFromTemplate("MMMd")
            return f
        }
    }

    /// "星期三" / "Wednesday" 按 `appLanguage` 锁定语言。
    static func weekdayFull(language: String) -> DateFormatter {
        cachedFormatter(key: "weekdayFull-\(language)") {
            let f = DateFormatter()
            f.locale = Locale(identifier: language)
            f.dateFormat = "EEEE"
            return f
        }
    }

    /// "27" 月内日期数字 — DiaryEntryRow day badge。按 `appLanguage` 锁定数字系。
    static func dayNumber(language: String) -> DateFormatter {
        cachedFormatter(key: "dayNumber-\(language)") {
            let f = DateFormatter()
            f.locale = Locale(identifier: language)
            f.dateFormat = "dd"
            return f
        }
    }

    /// "5月" / "May"(短月份)按 `appLanguage` 锁定语言。
    static func monthShortLocalized(language: String) -> DateFormatter {
        cachedFormatter(key: "monthShort-\(language)") {
            let f = DateFormatter()
            f.locale = Locale(identifier: language)
            f.dateFormat = "MMM"
            return f
        }
    }

    /// "9:30" / "9:30 AM" — `timeStyle=.short`,按 `appLanguage` 锁定语言/AM-PM。
    static func timeShortLocalized(language: String) -> DateFormatter {
        cachedFormatter(key: "timeShort-\(language)") {
            let f = DateFormatter()
            f.locale = Locale(identifier: language)
            f.timeStyle = .short
            return f
        }
    }
}
