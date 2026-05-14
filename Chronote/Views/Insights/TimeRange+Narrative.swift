import Foundation

// MARK: - TimeRange narrative title 共享 helper
//
// 浓缩卡 title + persistNarrative 的 AIConversation.title 共用同一份本地化文案。
// 放在 TimeRange extension 里(而不是 View / Service 里)是为了避免 service 层
// 反向依赖 View 类型 —— `NarrativePrecomputeService` 在后台 actor 里写盘时也要
// 拿到这个 title,直接用 `range.narrativeTitleLabel` 不需要 import View。

extension TimeRange {
    /// 浓缩卡 title + 持久化 record title 共用。
    /// 注意 `.month` 是"最近 30 天"滚动区间(see `dateInterval`),不是自然月。
    var narrativeTitleLabel: String {
        switch self {
        case .month:
            return NSLocalizedString("narrative.summary.title.month", comment: "Narrative title — month")
        case .quarter:
            return NSLocalizedString("narrative.summary.title.quarter", comment: "Narrative title — quarter")
        case .year:
            return NSLocalizedString("narrative.summary.title.year", comment: "Narrative title — year")
        case .all:
            return NSLocalizedString("narrative.summary.title.all", comment: "Narrative title — all time")
        }
    }
}
