import Foundation

// MARK: - Shared time-range model for Insights Dashboard
//
// 所有 Insights 子模块共享同一个 TimeRange，顶部选择器一改动，
// 下游的 MoodStoryChart / ThemeCard / CorrelationChip / Narrative 都重新查询。

enum TimeRange: String, CaseIterable, Identifiable, Equatable {
    case month, quarter, year, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .month: return NSLocalizedString("最近 30 天", comment: "Time range month")
        case .quarter: return NSLocalizedString("最近 3 个月", comment: "Time range quarter")
        case .year: return NSLocalizedString("最近 1 年", comment: "Time range year")
        case .all: return NSLocalizedString("全部时间", comment: "Time range all")
        }
    }

    var shortLabel: String {
        switch self {
        case .month: return NSLocalizedString("月", comment: "Month short")
        case .quarter: return NSLocalizedString("季", comment: "Quarter short")
        case .year: return NSLocalizedString("年", comment: "Year short")
        case .all: return NSLocalizedString("全部", comment: "All short")
        }
    }

    /// 起止范围。end 永远是"现在"；start 向前推（`all` 拉到远古时间，等效于不设下界）。
    var dateInterval: DateInterval {
        let now = Date()
        let calendar = Calendar.current
        let start: Date
        switch self {
        case .month:
            start = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .quarter:
            start = calendar.date(byAdding: .month, value: -3, to: now) ?? now
        case .year:
            start = calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .all:
            start = Date.distantPast
        }
        return DateInterval(start: start, end: now)
    }

    /// 图表 bucket：根据范围挑选合适粒度，点数稳定在 ~30 以内。
    var chartBucket: InsightsEngine.Bucket {
        switch self {
        case .month: return .day
        case .quarter: return .week
        case .year: return .month
        case .all: return .month
        }
    }
}
