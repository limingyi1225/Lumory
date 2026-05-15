import Foundation

// MARK: - LumoryDateFormatters
//
// `DateFormatter` 线程安全 since iOS 7,构造 ~1ms ICU 加载。集中共享避免长 list /
// 30fps 播放进度 body eval 重建。语言敏感的 accessor 见下方 MARK 段。

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

    // MARK: - Language-aware accessors
    //
    // 上面的 token 走 `Locale.current`(系统);用户用 `@AppStorage("appLanguage")` 在 App 内切语言
    // 时跟系统可能不一致 → list cell 必须按 `appLanguage` 显示走下面的组,带 language 缓存。

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
}
