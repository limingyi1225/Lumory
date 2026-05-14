import SwiftUI

// MARK: - WritingHeatmap
//
// GitHub contribution graph 风格的 22 周写作节奏色块图。
// 用户决定 2026-05-12 删 heroRow(原"🔥 连续 / 📖 累计 / Aa 字数"三个彩色 stat block)—
// 三种饱和度不同的色 icon 像游戏成就栏,跟 Lumory 反思 / 私人语气不合;streak=0 时的
// 熄灭火焰是负反馈。本期 entry 数已经在 NarrativeSummaryCard 底部 caption 里 inline,
// 全局累计 / streak 不再单独 vanity-display(用户主动想看可走 Settings)。
// 输入只剩 cells(每日 mood + wordCount)。

// DailyCell 已挪到 Chronote/Services/InsightsResultCache.swift(2026-05-13 superreview P1 fix)。
// Service 层不应反向引用 View 层类型。

struct WritingHeatmap: View {
    let cells: [DailyCell]
    let weeksToShow: Int
    /// tap / 长按 + 拖动 释放 时触发,InsightsView 接住打开 PointDetailSheet。
    /// **只对 `hasEntry && !isFuture` 触发**,空格 / 未来格不响应。
    /// nil = 不挂手势(向后兼容潜在的其他 caller)。
    let onSelectDay: ((Date) -> Void)?

    @State private var builtDays: [HeatCellModel] = []
    @State private var lastCellsIdentity: Int = -1
    // **P2 fix (2026-05-13 superreview)**:`monthLabelRuns` 之前是 computed property,每次
    // SwiftUI body diff 都重扫 22 week × 2 次 Calendar.component → ~100-200µs。跟 `builtDays`
    // 同源,memoize 进 @State 跟 rebuildIfNeeded 一起刷。
    @State private var monthLabelRunsCache: [MonthRun] = []

    // 布局常量
    private static let cellSide: CGFloat = 12
    private static let cellSpacing: CGFloat = 3
    private static let rowCount: Int = 7
    private static let gridCoordinateSpace: String = "lumory.heatmapGrid"
    private static var gridHeight: CGFloat {
        CGFloat(rowCount) * cellSide + CGFloat(rowCount - 1) * cellSpacing
    }

    init(
        cells: [DailyCell],
        weeksToShow: Int = 22,
        onSelectDay: ((Date) -> Void)? = nil
    ) {
        self.cells = cells
        self.weeksToShow = weeksToShow
        self.onSelectDay = onSelectDay
    }

    var body: some View {
        heatmapGrid
            .padding(16)
            .insightsCard()
            .onAppear { rebuildIfNeeded() }
            .onChange(of: cells) { _, _ in rebuildIfNeeded() }
    }

    // MARK: Heatmap grid

    private var heatmapGrid: some View {
        // 一周一列（7 行），横向滚动
        let rows = Array(repeating: GridItem(.fixed(Self.cellSide), spacing: Self.cellSpacing), count: Self.rowCount)
        return VStack(alignment: .leading, spacing: 8) {
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
                    // tap 手势挂在 grid 内容上,coordinateSpace 命名后 SpatialTapGesture 拿到的
                    // location 相对 LazyHGrid 内容(不受 ScrollView contentOffset 影响)→ 反推
                    // cell 索引用网格数学(cellAt)。**必须用 simultaneousGesture 而非 gesture**,
                    // 否则会拦截外层 ScrollView 的纵向滚动手势,用户下滑碰到热力图就卡住。
                    .coordinateSpace(name: Self.gridCoordinateSpace)
                    .simultaneousGesture(tapGesture)
                }
            }
            .frame(height: Self.gridHeight + 22)
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.trailing)  // 初次加载锚定到最新（最右）
        }
    }

    // MARK: Tap 手势
    //
    // SpatialTapGesture 在 LazyHGrid 整体上挂(simultaneously,不抢 ScrollView 滚动手势),
    // 拿到 location 后用网格数学反推 cell index — 比给每个 12pt 格子单独挂 tap 容错率高。
    // hasEntry == false 或 isFuture 不响应。

    private var tapGesture: some Gesture {
        SpatialTapGesture(coordinateSpace: .named(Self.gridCoordinateSpace))
            .onEnded { event in
                guard let onSelectDay,
                      let target = cellAt(point: event.location),
                      target.hasEntry, !target.isFuture else { return }
                HapticManager.shared.impact(.light)
                onSelectDay(target.date)
            }
    }

    /// 反推手指落点对应哪个 cell。LazyHGrid(rows:7) 是 column-major:
    ///   builtDays[col * 7 + row] 对应第 col 列第 row 行。
    /// 命中条件除了 index 在范围内,还要落点真在格子内(不是 spacing 间隙)— 用 modulo
    /// 检查 (x % colStride) < cellSide 等。否则用户在 spacing 上 release 也会随机捕获到一格。
    private func cellAt(point: CGPoint) -> HeatCellModel? {
        let colStride = Self.cellSide + Self.cellSpacing
        let rowStride = Self.cellSide + Self.cellSpacing
        guard point.x >= 0, point.y >= 0 else { return nil }
        guard point.x.truncatingRemainder(dividingBy: colStride) < Self.cellSide,
              point.y.truncatingRemainder(dividingBy: rowStride) < Self.cellSide else { return nil }
        let col = Int(point.x / colStride)
        let row = Int(point.y / rowStride)
        guard col >= 0, row >= 0, row < Self.rowCount else { return nil }
        let weekCount = builtDays.count / Self.rowCount
        guard col < weekCount else { return nil }
        let index = col * Self.rowCount + row
        guard index < builtDays.count else { return nil }
        return builtDays[index]
    }

    /// P1-Ins-6 月份 label 行 — 把连续同月的周聚合成一个 label,左对齐贴第一列。
    /// 间距精确匹配 grid 的 cellSpacing,跟下方网格列对齐。
    /// **2026-05-05 修复**:最右最后一 run 如果 weekSpan 小(≤2 周,即月初刚开始),frame width 不够
    /// 容下"5月"两字 + 中文 caption2 → 显示为"..."。改用 `.fixedSize` 让 Text 撑开自然宽度,
    /// frame 用 `minWidth` 保留跟列对齐的最低宽度,溢出允许(最后一 run 后没 sibling 不冲突)。
    @ViewBuilder
    private var monthLabelsRow: some View {
        HStack(alignment: .bottom, spacing: Self.cellSpacing) {
            ForEach(monthLabelRunsCache, id: \.startWeekIndex) { run in
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
    /// rebuildIfNeeded 调用,结果缓存进 monthLabelRunsCache 供 body 直接读。
    private func computeMonthLabelRuns() -> [MonthRun] {
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
        // tap 手势挂在 LazyHGrid 整体上(见 heatmapGrid)用网格数学反推 cell — cell 自己不挂手势,
        // 12pt 格子手指难精确按到。
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
            // **P2 fix (2026-05-14 superreview round 3)**:整网格 tap 走 SpatialTapGesture 反推
            // cell 打开 PointDetailSheet,VoiceOver 用户聚焦有日记的格子时没有等价 button action。
            // 给 `hasEntry && !isFuture` 的 cell 加 button trait + accessibilityAction,让 VO
            // 双击能进详情。空格 / 未来格不加(跟 tap 手势的响应条件一致)。
            .accessibilityAddTraits(day.hasEntry && !day.isFuture ? .isButton : [])
            .accessibilityAction {
                guard day.hasEntry, !day.isFuture else { return }
                HapticManager.shared.impact(.light)
                onSelectDay?(day.date)
            }
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
        // 跟 builtDays 同源,一并 memoize。
        monthLabelRunsCache = computeMonthLabelRuns()
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
}
