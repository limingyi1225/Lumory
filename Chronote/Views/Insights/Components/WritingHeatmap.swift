import SwiftUI

// MARK: - WritingHeatmap
//
// 第四块：类 GitHub contribution graph。
// 布局：每列 = 一周（7 格，顶部到底部是 firstWeekday 到最后一日），横向滚动。
// Hero 数字：连续天数 + 累计条目数 + 累计字数。
// 输入：stats + 一组 (date, mood, wordCount) dailyCell。

struct DailyCell: Identifiable, Equatable, Hashable {
    let date: Date
    let mood: Double
    let wordCount: Int
    var id: Date { date }
}

struct WritingHeatmap: View {
    let stats: InsightsEngine.WritingStats
    let cells: [DailyCell]
    let weeksToShow: Int

    @State private var builtDays: [HeatCellModel] = []
    @State private var lastCellsIdentity: Int = -1

    // 布局常量
    private static let cellSide: CGFloat = 12
    private static let cellSpacing: CGFloat = 3
    private static let rowCount: Int = 7
    private static var gridHeight: CGFloat {
        CGFloat(rowCount) * cellSide + CGFloat(rowCount - 1) * cellSpacing
    }

    init(stats: InsightsEngine.WritingStats, cells: [DailyCell], weeksToShow: Int = 22) {
        self.stats = stats
        self.cells = cells
        self.weeksToShow = weeksToShow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroRow
            heatmapGrid
        }
        .padding(16)
        .insightsCard()
        .onAppear { rebuildIfNeeded() }
        .onChange(of: cells) { _, _ in rebuildIfNeeded() }
    }

    // MARK: Hero

    private var heroRow: some View {
        HStack(alignment: .center, spacing: 20) {
            statBlock(
                value: "\(stats.currentStreak)",
                label: NSLocalizedString("连续天数", comment: "Current streak"),
                icon: "flame.fill",
                tint: .orange,
                a11y: String(format: NSLocalizedString("当前连续 %d 天写作", comment: "A11y: streak"), stats.currentStreak)
            )
            Divider().frame(height: 40)
            statBlock(
                value: "\(stats.totalEntries)",
                label: NSLocalizedString("累计条目", comment: "Total entries"),
                icon: "book.fill",
                tint: .indigo,
                a11y: String(format: NSLocalizedString("累计 %d 条日记", comment: "A11y: total entries"), stats.totalEntries)
            )
            Divider().frame(height: 40)
            statBlock(
                value: compactNumber(stats.totalWords),
                label: NSLocalizedString("累计字数", comment: "Total words"),
                icon: "textformat",
                tint: .teal,
                a11y: String(format: NSLocalizedString("累计 %d 字", comment: "A11y: total words"), stats.totalWords)
            )
        }
    }

    private func statBlock(value: String, label: String, icon: String, tint: Color, a11y: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11y)
    }

    // MARK: Heatmap grid

    private var heatmapGrid: some View {
        // 一周一列（7 行），横向滚动
        let rows = Array(repeating: GridItem(.fixed(Self.cellSide), spacing: Self.cellSpacing), count: Self.rowCount)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(NSLocalizedString("书写热力", comment: "Writing heatmap"))
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                // P1-Ins-6 月份 label + 网格放同 ScrollView 里,横滑同步。每个 label 宽度
                // = 该月覆盖的周数对应的格子总宽,左对齐让"几月"贴在那个月第一列上方。
                VStack(alignment: .leading, spacing: 4) {
                    monthLabelsRow
                    LazyHGrid(rows: rows, spacing: Self.cellSpacing) {
                        ForEach(builtDays) { day in
                            cell(for: day)
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
            .frame(height: Self.gridHeight + 22)
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.trailing)  // 初次加载锚定到最新（最右）
        }
    }

    /// P1-Ins-6 月份 label 行 — 把连续同月的周聚合成一个 label,左对齐贴第一列。
    /// 间距精确匹配 grid 的 cellSpacing,跟下方网格列对齐。
    /// **2026-05-05 修复**:最右最后一 run 如果 weekSpan 小(≤2 周,即月初刚开始),frame width 不够
    /// 容下"5月"两字 + 中文 caption2 → 显示为"..."。改用 `.fixedSize` 让 Text 撑开自然宽度,
    /// frame 用 `minWidth` 保留跟列对齐的最低宽度,溢出允许(最后一 run 后没 sibling 不冲突)。
    @ViewBuilder
    private var monthLabelsRow: some View {
        HStack(alignment: .bottom, spacing: Self.cellSpacing) {
            ForEach(monthLabelRuns, id: \.startWeekIndex) { run in
                Text(run.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(
                        minWidth: CGFloat(run.weekSpan) * Self.cellSide
                            + CGFloat(max(0, run.weekSpan - 1)) * Self.cellSpacing,
                        alignment: .leading
                    )
                    .accessibilityHidden(true) // 月份对每个 cell 已经在 dayA11yLabel 里写过完整日期,这层冗余。
            }
        }
        .padding(.horizontal, 1)
    }

    /// 把 builtDays 按周扫描,生成"连续同月"的 run 列表。每 run 一个 label。
    private var monthLabelRuns: [MonthRun] {
        guard !builtDays.isEmpty else { return [] }
        let calendar = Calendar.current
        let weekCount = builtDays.count / Self.rowCount
        guard weekCount > 0 else { return [] }

        var runs: [MonthRun] = []
        // run 切换条件用 (month, year) 二元组,不只 month。当 weeksToShow 涨到 ≥53 跨整年时,
        // 仅看 month 会把 Jan 2025 和 Jan 2026 合并 → label 异常(reviewer Wave-D BUG-P2)。
        // 当前默认 weeksToShow=22 (~5 个月) 不命中,但 init 暴露此参数,future caller 升级即踩。
        var currentKey: (month: Int, year: Int)? = nil
        var runStart: Int = 0

        for w in 0..<weekCount {
            // 取每周的第一天(grid 顶部那行)代表本周的"主月份";
            // 即便周跨月,label 仍贴在这个月开始的列上方,视觉简单稳定。
            let weekFirstIdx = w * Self.rowCount
            guard weekFirstIdx < builtDays.count else { break }
            let date = builtDays[weekFirstIdx].date
            let month = calendar.component(.month, from: date)
            let year = calendar.component(.year, from: date)
            let key = (month: month, year: year)

            if currentKey?.month != key.month || currentKey?.year != key.year {
                if let prev = currentKey {
                    let prevDate = builtDays[runStart * Self.rowCount].date
                    runs.append(MonthRun(
                        startWeekIndex: runStart,
                        weekSpan: w - runStart,
                        label: LumoryDateFormatters.monthShort.string(from: prevDate),
                        month: prev.month
                    ))
                }
                currentKey = key
                runStart = w
            }
        }
        if let prev = currentKey {
            let prevDate = builtDays[runStart * Self.rowCount].date
            runs.append(MonthRun(
                startWeekIndex: runStart,
                weekSpan: weekCount - runStart,
                label: LumoryDateFormatters.monthShort.string(from: prevDate),
                month: prev.month
            ))
        }
        return runs
    }

    private struct MonthRun {
        let startWeekIndex: Int
        let weekSpan: Int
        let label: String
        let month: Int
    }

    @ViewBuilder
    private func cell(for day: HeatCellModel) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(fillFor(day))
            .frame(width: Self.cellSide, height: Self.cellSide)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.primary.opacity(day.hasEntry ? 0.1 : 0), lineWidth: 0.5)
            )
            .opacity(day.isFuture ? 0 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(dayA11yLabel(day))
    }

    private func fillFor(_ day: HeatCellModel) -> Color {
        if day.isFuture { return .clear }
        guard day.hasEntry else { return Color.secondary.opacity(0.08) }
        let intensity = min(1.0, 0.35 + Double(day.wordCount) / 400.0)
        return Color.moodSpectrum(value: day.mood).opacity(intensity)
    }

    // MARK: Model

    struct HeatCellModel: Identifiable, Equatable {
        let date: Date
        let hasEntry: Bool
        let mood: Double
        let wordCount: Int
        let isFuture: Bool
        var id: Date { date }
    }

    // MARK: Cache / build

    private func rebuildIfNeeded() {
        // 必须 hash 全部 cell —— 之前只 sample first/last，用户编辑中间某天的 mood/wordCount
        // hash 不变，cache 不重建，热力图显示陈旧数据。N ≤ 366（最多一年）成本可忽略。
        var hasher = Hasher()
        hasher.combine(weeksToShow)
        hasher.combine(cells.count)
        for cell in cells { hasher.combine(cell) }
        let identity = hasher.finalize()
        guard identity != lastCellsIdentity else { return }
        lastCellsIdentity = identity
        builtDays = buildDays()
    }

    /// 构建对齐到周边界的 weeksToShow × 7 格子。
    /// 第一格 = 最早一周的 firstWeekday 这天；最后一格 = 当前周的 lastWeekday 这天；
    /// 今天之后的格子标 `isFuture = true`（渲染为透明），保证所有月份对齐。
    private func buildDays() -> [HeatCellModel] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // 找出本周最后一天（firstWeekday + 6）
        let todayWeekday = calendar.component(.weekday, from: today)     // 1..7
        let firstWeekday = calendar.firstWeekday                         // 1..7
        let daysToWeekEnd = (firstWeekday + 6 - todayWeekday + 7) % 7
        guard let gridEnd = calendar.date(byAdding: .day, value: daysToWeekEnd, to: today),
              let gridStart = calendar.date(byAdding: .day, value: -(weeksToShow * 7 - 1), to: gridEnd) else {
            return []
        }

        var lookup: [Date: DailyCell] = [:]
        lookup.reserveCapacity(cells.count)
        for cell in cells { lookup[calendar.startOfDay(for: cell.date)] = cell }

        var result: [HeatCellModel] = []
        result.reserveCapacity(weeksToShow * 7)
        for i in 0..<(weeksToShow * 7) {
            guard let date = calendar.date(byAdding: .day, value: i, to: gridStart) else { continue }
            let day = calendar.startOfDay(for: date)
            let isFuture = day > today
            if !isFuture, let cell = lookup[day] {
                result.append(HeatCellModel(date: day, hasEntry: true, mood: cell.mood, wordCount: cell.wordCount, isFuture: false))
            } else {
                result.append(HeatCellModel(date: day, hasEntry: false, mood: 0.5, wordCount: 0, isFuture: isFuture))
            }
        }
        return result
    }

    private func dayA11yLabel(_ day: HeatCellModel) -> String {
        let dateStr = day.date.formatted(date: .abbreviated, time: .omitted)
        if day.isFuture {
            return dateStr + "，" + NSLocalizedString("未来", comment: "A11y future day")
        }
        if day.hasEntry {
            return String(
                format: NSLocalizedString("%@，情绪 %d 分，%d 字", comment: "A11y heat cell with data"),
                dateStr, Int(day.mood * 100), day.wordCount
            )
        }
        return dateStr + "，" + NSLocalizedString("无日记", comment: "A11y heat cell empty")
    }

    private func compactNumber(_ number: Int) -> String {
        if number >= 10000 {
            return String(format: "%.1fw", Double(number) / 10000.0)
        } else if number >= 1000 {
            return String(format: "%.1fk", Double(number) / 1000.0)
        }
        return "\(number)"
    }
}
