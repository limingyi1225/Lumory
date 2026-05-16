import SwiftUI
import CoreData

// MARK: - ThemeCardList
//
// Insights Dashboard 第二块。横向滚动卡片：主题名、出现次数、平均心情(gradient blob)。
// 点击卡片 → 触发 onSelect，外部视图负责导航到筛选后的日记列表。

struct ThemeCardList: View {
    let themes: [InsightsEngine.Theme]
    let isLoading: Bool
    let onSelect: (InsightsEngine.Theme) -> Void
    /// 长按 → 弹出"删除主题"菜单时回调,父视图负责走确认 alert + ThemeManagementService。nil 表示禁用删除。
    var onDelete: ((InsightsEngine.Theme) -> Void)? = nil
    /// 长按 → "合并到其他主题"菜单时回调,父视图负责弹 sheet 让用户选 target。nil 表示禁用合并。
    var onMergeRequest: ((InsightsEngine.Theme) -> Void)? = nil

    /// wave17 — 2 行横滚 page-chunked。一页 = 2 行 × N 列(N 跟 size class 走)。
    /// 之前 LazyHGrid column-major + 自定义 ScrollTargetBehavior 在 SwiftUI 26 snap 完全失效。
    /// 改成 **themes 按 N×2 个一组分页 → LazyHStack 每 child 是一整页 → .viewAligned**
    /// 让 SwiftUI 走 stock 的"page-as-child" snap,翻一下精确出 N×2 张新卡。row-major 阅读顺序
    /// 比 column-major 更直观(从左到右、上到下读)。
    /// **iPad regular size class** 走 3 列 × 2 行 = 6 张/页(superreview P1-5):iPhone tuning
    /// 的 372pt pageWidth 在 iPad ~1000pt viewport 上嵌大段空白,扩 cardsPerPage 让 hero
    /// dashboard 信息密度匹配 iPad 屏宽。
    private static let cardRowHeight: CGFloat = 100
    private static let cardWidth: CGFloat = 180
    private static let columnSpacing: CGFloat = 12

    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var columnsPerPage: Int { hSizeClass == .regular ? 3 : 2 }
    private var cardsPerPage: Int { columnsPerPage * 2 }
    private var pageWidth: CGFloat {
        // pageWidth = columns × cardWidth + (columns - 1) × columnSpacing。iPhone 2 列=372pt,
        // iPad 3 列=564pt。LazyHStack 间 columnSpacing(12pt) gap 让翻页时 next page 第一列卡
        // 左边稍稍露出来作 affordance。
        CGFloat(columnsPerPage) * Self.cardWidth + CGFloat(columnsPerPage - 1) * Self.columnSpacing
    }

    /// 把 themes 切成 cardsPerPage 张一组,每组渲染成独立 page view 给 LazyHStack。
    /// 最后一页不足 cardsPerPage 张的位置用 Color.clear placeholder 占位,N×2 网格不塌。
    private var pagedThemes: [[InsightsEngine.Theme]] {
        let perPage = cardsPerPage
        return stride(from: 0, to: themes.count, by: perPage).map { start in
            Array(themes[start..<min(start + perPage, themes.count)])
        }
    }

    /// 取候选 ID 的尾部(entryIds 按 date ASC,suffix 即最近 N 条)。
    /// loadSnippets 的 fetchLimit=3,默认传 20 是历史 over-allocation —— SQL `IN` 子句多 17 个 UUID
    /// 没收益(superreview P2-13 fix)。需要更多候选的调用方可显式覆盖 limit。
    static func previewCandidateEntryIDs(from entryIds: [UUID], limit: Int = 3) -> [UUID] {
        guard limit > 0 else { return [] }
        return Array(entryIds.suffix(limit))
    }

    var body: some View {
        // 标题 "主题" 删除(用户决定 2026-05-12):跟"情绪故事"标题一起去掉,统一无 title 风格;
        // 横滑卡列本身的色斑 + 主题名 + 次数已 self-evident。VStack 外壳保留只是把
        // skeleton/empty/正常态包成一个 view block,不再带 title。
        Group {
            if isLoading && themes.isEmpty {
                skeleton
            } else if themes.isEmpty {
                emptyState
            } else {
                // 横向 ScrollView 跨越了外层 Insights 的 GlassEffectContainer 边界,
                // 这里再套一层自己的 container,确保卡片之间的折射/模糊能正确合批并一次性渲染。
                // 垂直 24pt 给 glass interactive 抬升投影充分的呼吸空间——
                // 12pt 时投影虽然不被裁但显得局促,放到 24 后整张卡感觉是"自然浮起",
                // 不像被夹在 section 之间的「凸起色块」。
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 12) {
                        // wave17 — themes 按 4 张一组打包成 page,LazyHStack 每个 child 是一整页
                        // (2×2 mini grid)。`.scrollTargetLayout()` 标识这些 page 作 snap target,
                        // `.viewAligned` 让翻一下精确滚 1 page 372pt,正好出 4 张新卡。
                        // 上一版的自定义 ColumnPagingBehavior 在 iOS 26 行为不稳(snap 失效),用
                        // page-as-child 这条 stock SwiftUI 路径绕开。
                        LazyHStack(alignment: .top, spacing: Self.columnSpacing) {
                            ForEach(Array(pagedThemes.enumerated()), id: \.offset) { _, pageThemes in
                                themePageView(pageThemes)
                                    .frame(width: pageWidth)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 24)
                    }
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    /// 单页 N×2 mini grid。row-major 阅读顺序(N = columnsPerPage):
    ///   iPhone(N=2): [0,1] / [2,3]
    ///   iPad  (N=3): [0,1,2] / [3,4,5]
    /// 最后一页不足 cardsPerPage 张的位置用透明 placeholder 占位,N×2 网格不会塌。
    @ViewBuilder
    private func themePageView(_ pageThemes: [InsightsEngine.Theme]) -> some View {
        let cols = columnsPerPage
        VStack(alignment: .leading, spacing: Self.columnSpacing) {
            HStack(spacing: Self.columnSpacing) {
                ForEach(0..<cols, id: \.self) { col in
                    themeCardOrPlaceholder(at: col, in: pageThemes)
                }
            }
            HStack(spacing: Self.columnSpacing) {
                ForEach(0..<cols, id: \.self) { col in
                    themeCardOrPlaceholder(at: col + cols, in: pageThemes)
                }
            }
        }
    }

    @ViewBuilder
    private func themeCardOrPlaceholder(at index: Int, in pageThemes: [InsightsEngine.Theme]) -> some View {
        if index < pageThemes.count {
            themeButton(for: pageThemes[index])
        } else {
            // 让 2×2 grid 在最后一页只有 1-3 张卡时仍保持对齐(否则下方 row 会左右晃)。
            Color.clear
                .frame(width: Self.cardWidth, height: Self.cardRowHeight)
        }
    }

    @ViewBuilder
    private func themeButton(for theme: InsightsEngine.Theme) -> some View {
        // 关键:**Button + .plain** 而不是 onTapGesture。
        // - PressableScaleButtonStyle:scale 动画与 contextMenu"卡片浮起"
        //   动画 + GlassEffectContainer detach 三层叠加 → 视觉诡异
        // - 纯 onTapGesture:在 iOS 26 + GlassEffectContainer 内会抢手势链,
        //   长按完全无反应(用户实测)
        // - Button + .plain:无 scale 动画,但 Button 协议层让 SwiftUI
        //   知道怎么把 tap 和 contextMenu 的 long-press 分开调度,长按能正常触发。
        Button {
            #if canImport(UIKit)
            HapticManager.shared.click()
            #endif
            onSelect(theme)
        } label: {
            ThemeCard(theme: theme)
                .frame(width: Self.cardWidth, height: Self.cardRowHeight)
                .contentShape(RoundedRectangle(cornerRadius: LumoryCornerRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu(menuItems: {
            if let onMergeRequest {
                Button {
                    onMergeRequest(theme)
                } label: {
                    Label(
                        NSLocalizedString("合并到其他主题…", comment: "Merge into another theme"),
                        systemImage: "arrow.triangle.merge"
                    )
                }
            }
            if let onDelete {
                Button(role: .destructive) {
                    onDelete(theme)
                } label: {
                    Label(
                        NSLocalizedString("删除主题", comment: "Delete theme"),
                        systemImage: "trash"
                    )
                }
            }
        }, preview: {
            // **显式 preview**:跳过 iOS 默认快照(否则 GlassEffectContainer
            // 的外延 + 系统 backdrop 圆角阴影会让"卡片大一点的深色框先闪一下")。
            // 直接渲染最近 3 条相关日记的 snippet,长按等于一次性看到主题
            // "代表了哪些片段",不需要再 tap 进 filtered list。
            ThemeCardPreview(theme: theme)
        })
    }

    private var skeleton: some View {
        // 2 张占位 page(8 个 placeholder)— 跟真实 LazyHStack page 同 layout 避免出场跳变。
        LazyHStack(alignment: .top, spacing: Self.columnSpacing) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Self.columnSpacing) {
                    HStack(spacing: Self.columnSpacing) {
                        ForEach(0..<columnsPerPage, id: \.self) { _ in
                            skeletonCard
                        }
                    }
                    HStack(spacing: Self.columnSpacing) {
                        ForEach(0..<columnsPerPage, id: \.self) { _ in
                            skeletonCard
                        }
                    }
                }
                .frame(width: pageWidth)
            }
        }
        .padding(.horizontal, 16)
    }

    private var skeletonCard: some View {
        RoundedRectangle(cornerRadius: LumoryCornerRadius.card)
            .fill(Color.secondary.opacity(0.06))
            .frame(width: Self.cardWidth, height: Self.cardRowHeight)
    }

    private var emptyState: some View {
        HStack {
            Text(NSLocalizedString("暂无主题，或日记还太少", comment: "Empty themes"))
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - ThemeCardPreview (contextMenu long-press preview)
//
// 长按主题卡时弹出来的"展开预览":主题名 + 出现次数 + 最近 3 条日记的 date + 摘要片段。
// 长按等于"快速翻一眼这主题代表了哪些片段",不必先 tap 进 filtered list。
//
// **加载策略**:contextMenu preview 的 view 在长按时才被实例化。`.task` 进异步 fetch,
// 第一帧显示 placeholder,fetch 完(~50-200ms,3 条 entry 的 batch fetch)替换。
// 用户即使在 fetch 完成前松手菜单(取消),task 也会被 SwiftUI 自动 cancel。

private struct ThemeCardPreview: View {
    let theme: InsightsEngine.Theme

    @State private var snippets: [Snippet] = []
    @State private var isLoading = true

    private struct Snippet: Identifiable, Equatable {
        let id: UUID
        let date: Date
        let mood: Double
        let text: String  // summary 优先,fallback raw text 前 90 字
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header:主题名 + 总条目数
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.moodSpectrum(value: theme.avgMood))
                    .frame(width: 10, height: 10)
                Text(theme.name)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(String(format: NSLocalizedString("%d 篇", comment: "Entry count short"), theme.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider().opacity(0.4)

            if isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(NSLocalizedString("加载中…", comment: "Loading"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else if snippets.isEmpty {
                Text(NSLocalizedString("没找到相关日记", comment: "No related entries"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(snippets) { snip in
                    snippetRow(snip)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .liquidGlassCard(cornerRadius: LumoryCornerRadius.card, interactive: false)
        .task {
            await loadSnippets()
        }
    }

    @ViewBuilder
    private func snippetRow(_ snip: Snippet) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // 左侧 mood 色点 —— 让用户对每篇日记的情绪一眼可见
            Circle()
                .fill(Color.moodSpectrum(value: snip.mood))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(LumoryDateFormatters.monthDay.string(from: snip.date))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(snip.text)
                    .font(.caption)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func loadSnippets() async {
        // 取最近 3 条 —— 长按 preview 不需要全部
        let candidateIDs = ThemeCardList.previewCandidateEntryIDs(from: theme.entryIds)
        guard !candidateIDs.isEmpty else {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.isLoading = false
            }
            return
        }
        let fetched = await PersistenceController.shared.container.performBackgroundTask { context -> [Snippet] in
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", candidateIDs as NSArray)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
            request.fetchLimit = 3
            guard let entries = try? context.fetch(request) else { return [] }
            return entries.compactMap { entry -> Snippet? in
                guard let id = entry.id, let date = entry.date else { return nil }
                let summary = entry.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let raw = (summary.isEmpty ? (entry.text ?? "") : summary)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                let trimmed = String(raw.prefix(90)) + (raw.count > 90 ? "…" : "")
                return Snippet(
                    id: id,
                    date: date,
                    mood: entry.moodValue,
                    text: trimmed.isEmpty ? NSLocalizedString("(空)", comment: "Empty entry") : trimmed
                )
            }
        }
        guard !Task.isCancelled else { return }
        await MainActor.run {
            self.snippets = fetched
            self.isLoading = false
        }
    }
}

// MARK: - Single Theme Card

struct ThemeCard: View {
    let theme: InsightsEngine.Theme

    /// 「混合」= 同时存在两极条目且色距足够大。两个条件都要满足:
    /// 1. lowCount/highCount 都 ≥ 1 —— 否则没东西可"分两色";
    /// 2. moodHigh - moodLow ≥ 0.22 —— 否则两极颜色太接近,不值得做对比渲染。
    private var isMixed: Bool {
        theme.lowCount >= 1
            && theme.highCount >= 1
            && (theme.moodHigh - theme.moodLow) >= 0.22
    }

    private var avgColor: Color { Color.moodSpectrum(value: theme.avgMood) }
    private var lowColor: Color { Color.moodSpectrum(value: theme.moodLow) }
    private var highColor: Color { Color.moodSpectrum(value: theme.moodHigh) }

    /// 高/低情绪条目占总数的比例(0...1)。控制色斑半径——多数派的色斑大,少数派的小。
    /// 中性条目不算进任一池,所以 highShare + lowShare ≤ 1,中性多的主题两个色斑都小。
    private var highShare: Double { Double(theme.highCount) / max(1.0, Double(theme.count)) }
    private var lowShare: Double { Double(theme.lowCount) / max(1.0, Double(theme.count)) }

    /// 色斑 endRadius:`base + extra * share`。
    /// base=对角线 0.32 给少数派至少一团可见的柔光;extra=0.55 让多数派接近覆盖整张卡。
    private func blobRadius(share: Double, in size: CGSize) -> CGFloat {
        let diagonal = hypot(size.width, size.height)
        return diagonal * (0.32 + 0.55 * CGFloat(share))
    }

    /// 主题名 → 稳定 hash(djb2)。Swift `Hashable.hashValue` 启动时随机化,
    /// 同一主题每次进 Insights 都会换布局——不是我们想要的稳定身份。
    private var stableHash: Int {
        var hash = 5381
        for byte in theme.name.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ Int(byte)
        }
        return hash & .max
    }

    /// 混合主题的两点对位组合:只走对角线方向。
    /// 纯竖(top↕bottom)/纯横(leading↔trailing)视觉上像图书馆色卡,不够灵动。
    private static let mixedAnchors: [(UnitPoint, UnitPoint)] = [
        (.topLeading, .bottomTrailing),
        (.topTrailing, .bottomLeading)
    ]

    /// 单色主题的单点落点,8 个候选给一行卡片足够多样。
    private static let solidAnchors: [UnitPoint] = [
        .topLeading, .topTrailing, .bottomLeading, .bottomTrailing,
        .top, .bottom, .leading, .trailing
    ]

    /// 单色主题色斑半径——比混合更大,差不多覆盖大半张卡,
    /// 但仍按 RadialGradient 衰减到边缘 0,保留玻璃白边。
    private func solidBlobRadius(in size: CGSize) -> CGFloat {
        hypot(size.width, size.height) * 0.85
    }

    /// 卡片柔光背景:混合 → 双点;单色 → 单点;落点位置由主题名决定。
    /// 中心 alpha 都压在 ~0.30 内,RadialGradient 平滑衰减到 0,
    /// 卡的中段大多数像素没被着色——视觉主调始终是玻璃白。
    @ViewBuilder
    private var cardBackground: some View {
        GeometryReader { geo in
            ZStack {
                if isMixed {
                    // 混合卡:中心 alpha 0.20,比单色更浅——红+蓝两色叠加时已经足够分辨,
                    // 浓度太高反而抢了玻璃白底的主调。
                    let pair = Self.mixedAnchors[stableHash % Self.mixedAnchors.count]
                    RadialGradient(
                        gradient: Gradient(colors: [highColor.opacity(0.20), highColor.opacity(0)]),
                        center: pair.0,
                        startRadius: 0,
                        endRadius: blobRadius(share: highShare, in: geo.size)
                    )
                    RadialGradient(
                        gradient: Gradient(colors: [lowColor.opacity(0.20), lowColor.opacity(0)]),
                        center: pair.1,
                        startRadius: 0,
                        endRadius: blobRadius(share: lowShare, in: geo.size)
                    )
                } else {
                    let anchor = Self.solidAnchors[stableHash % Self.solidAnchors.count]
                    RadialGradient(
                        gradient: Gradient(colors: [avgColor.opacity(0.32), avgColor.opacity(0)]),
                        center: anchor,
                        startRadius: 0,
                        endRadius: solidBlobRadius(in: geo.size)
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: LumoryCornerRadius.card, style: .continuous))
        }
    }

    var body: some View {
        // 用户决定 2026-05-12 改竖排:原"name + count 同行"+ 底部"色点 + 积极 + 64" 把 mood
        // 这件事在卡内表达了三次(gradient bg / 色点 / 数字),冗余且抢走 gradient blob 的存在
        // 感。新布局:name 占一行,count 单独一行 caption,底部完全留白让 gradient blob 呼吸 —
        // 卡片更"标签感"而非"成绩单"。
        // (2026-05-16 删 sparkline:固定 6 bucket + 空桶填 0.5 的设计产出"假视觉密度",
        // 3 篇日记折线却有 4 段折点,反直觉。trend 字段已从 Theme 移除。)
        VStack(alignment: .leading, spacing: 4) {
            Text(theme.name)
                // **P2 fix (2026-05-13 superreview)**:之前硬编码 18 → 改 LumoryFonts.themeCardTitle。
                .font(LumoryFonts.themeCardTitle)
                .lineLimit(1)

            Text(String(format: NSLocalizedString("%d 次", comment: "Theme count"), theme.count))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // wave17 — minHeight 130 → 100。ThemeCardList 现在用 LazyHStack page-chunked + 显式
        // `.frame(width: cardWidth, height: cardRowHeight)`(100pt),minHeight 这里只是给
        // 独立 preview / 非 page-chunked 用法的兜底。
        .frame(minHeight: 100)
        // 所有主题统一走「玻璃白底 + 柔光色斑」语言:tint=nil 让 glass 保持白调,
        // RadialGradient 提供色彩信号。混合主题双点,单色主题单点;落点按主题名 hash 多样化。
        // interactive=true 保留 glass 的 hover/press 高光,父 ScrollView 已留 12pt 垂直空间防裁剪。
        .background { cardBackground }
        .liquidGlassCard(
            cornerRadius: LumoryCornerRadius.card,
            tint: nil,
            interactive: true
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        // VoiceOver 用户看不见 gradient blob,a11y label 仍要把 mood 数字朗读出来,跟 hint 顺畅。
        if isMixed {
            return String(
                format: NSLocalizedString("主题 %@，出现 %d 次，情绪起伏 %d 到 %d 分", comment: "A11y: mixed theme"),
                theme.name, theme.count, Int(theme.moodLow * 100), Int(theme.moodHigh * 100)
            )
        }
        return String(
            format: NSLocalizedString("主题 %@，出现 %d 次，平均情绪 %d 分", comment: "A11y: theme card"),
            theme.name, theme.count, Int(theme.avgMood * 100)
        )
    }

}
