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
                LazyHGrid(rows: rows, spacing: Self.cellSpacing) {
                    ForEach(builtDays) { day in
                        cell(for: day)
                    }
                }
                .padding(.horizontal, 1)
            }
            .frame(height: Self.gridHeight)
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.trailing)  // 初次加载锚定到最新（最右）
        }
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
        var hasher = Hasher()
        hasher.combine(weeksToShow)
        hasher.combine(cells.count)
        hasher.combine(cells.first?.date)
        hasher.combine(cells.last?.date)
        hasher.combine(cells.first?.wordCount)
        hasher.combine(cells.last?.wordCount)
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
        for c in cells { lookup[calendar.startOfDay(for: c.date)] = c }

        var result: [HeatCellModel] = []
        result.reserveCapacity(weeksToShow * 7)
        for i in 0..<(weeksToShow * 7) {
            guard let d = calendar.date(byAdding: .day, value: i, to: gridStart) else { continue }
            let day = calendar.startOfDay(for: d)
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
        let f = DateFormatter()
        f.dateStyle = .medium
        let dateStr = f.string(from: day.date)
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

    private func compactNumber(_ n: Int) -> String {
        if n >= 10000 {
            return String(format: "%.1fw", Double(n) / 10000.0)
        } else if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000.0)
        }
        return "\(n)"
    }
}
