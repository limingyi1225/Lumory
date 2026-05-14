import SwiftUI

enum LumoryFonts {
    static let narrativeEyebrow: Font = .system(size: 14, weight: .semibold)
    static let narrativeHeadline: Font = .system(size: 19, weight: .medium, design: .serif)
    static let narrativeMeta: Font = .system(size: 11, weight: .semibold)
    static let narrativeBodyTitle: Font = .system(size: 22, weight: .medium, design: .serif)

    static let diaryHeroTitle: Font = .system(size: 22, weight: .semibold, design: .rounded)
    static let diaryImagePlaceholder: Font = .system(size: 36)

    static let composerPlaceholder: Font = .system(size: 16)
    static let composerBody: Font = .system(size: 17)
    static let composerToolbarIcon: Font = .system(size: 18, weight: .medium)
    static let composerSendIcon: Font = .system(size: 16, weight: .bold)

    /// Entry row 日期 badge 数字(24pt bold) — DiaryEntryRow 用。语义化为 token 让全 row
    /// 视觉权重一致;走 system size 而非 `.title2`(22pt baseline)是为了 24pt 数字与右侧 summary
    /// 形成更明确的视觉锚点。
    static let entryDateBadge: Font = .system(size: 24, weight: .bold)
    /// HomeTimelineCard 第二行 body preview(13pt) — 介于 `.caption`(12)和 `.footnote`(13)。
    /// 用 token 保持跟 DiaryEntryRow text preview 等其他 row 一致。
    static let timelineCardPreview: Font = .system(size: 13)

    /// ThemeCardList 主题卡标题(18pt semibold) — 跟 narrativeHeadline(19pt serif)拉开
    /// 一档不抢主卡 hero;比 `.headline`(17pt)更接近主题感。
    static let themeCardTitle: Font = .system(size: 18, weight: .semibold)
}
