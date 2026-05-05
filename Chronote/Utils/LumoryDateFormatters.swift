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
}
