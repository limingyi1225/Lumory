import SwiftUI
import CoreData

// MARK: - CalendarMonthModule
//
// InsightsView 的月历模块。
// - 顶部月份标题 + 左右箭头切换（去掉了横向 drag —— 和外层纵向 ScrollView 手势冲突太大）
// - 网格按天着色（该日均值 mood → Color.moodSpectrum）
// - 点击有日记的那天 → 回调给父视图，弹出当天详情
//
// 性能：
// - `moodByDay` / `makeDays` 结果用 @State 缓存，输入变化才重算。
// - 固定 6 行高度，避免月份换行时整个布局抖动、裁剪。

struct CalendarMonthModule: View {
    let cells: [DailyCell]
    let onSelectDate: (Date) -> Void

    @State private var displayedMonth: Date = Date()
    @State private var moodByDay: [Date: Double] = [:]
    @State private var daysByMonthKey: [Date: [Date?]] = [:]
    @State private var lastCellsIdentity: Int = 0

    private let calendar = Calendar.current

    // 固定 6 行 —— 覆盖所有可能的月份布局；差的月份底部留白即可，比跳动好看。
    private static let gridRows: Int = 6
    private static let cellHeight: CGFloat = 36
    private static let rowSpacing: CGFloat = 6
    private static var gridHeight: CGFloat {
        CGFloat(gridRows) * cellHeight + CGFloat(gridRows - 1) * rowSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            weekdayLabels
            grid
                .frame(height: Self.gridHeight)
                .animation(.interpolatingSpring(stiffness: 320, damping: 28), value: displayedMonth)
        }
        .padding(16)
        .insightsCard()
        .onAppear { rebuildCachesIfNeeded() }
        .onChange(of: cells) { _, _ in rebuildCachesIfNeeded() }
        .onChange(of: displayedMonth) { _, _ in ensureDaysCached() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { changeMonth(by: -1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("上个月", comment: "Previous month"))
            .disabled(!canGoBack)
            .opacity(canGoBack ? 1.0 : 0.3)

            Text(monthYearString(for: displayedMonth))
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)
                .contentTransition(.numericText())
                .accessibilityAddTraits(.isHeader)

            Button { changeMonth(by: 1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("下个月", comment: "Next month"))
            .disabled(!canGoForward)
            .opacity(canGoForward ? 1.0 : 0.3)
        }
        .foregroundColor(.primary)
    }

    private var weekdayLabels: some View {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 0) {
            ForEach(ordered.indices, id: \.self) { i in
                Text(ordered[i])
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Grid (single month, no drag)

    @ViewBuilder
    private var grid: some View {
        let daysInMonth = days(for: displayedMonth)
        // 填充到 42 格（6×7），没用的格子渲染透明占位，保证高度稳定
        let padded = daysInMonth + Array(repeating: Date?.none, count: max(0, 42 - daysInMonth.count))
        // 不套 GlassEffectContainer:小尺寸 disc + container 合批渲染时
        // glass 材质会被压成不透明色块,数字看不见。每个 disc 独立 glassEffect 反而正常。
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
            spacing: Self.rowSpacing
        ) {
            ForEach(Array(padded.enumerated()), id: \.0) { _, day in
                if let day {
                    dayCell(for: day)
                } else {
                    Color.clear.frame(height: Self.cellHeight)
                }
            }
        }
        .transition(.opacity)
        .id(monthKey(displayedMonth))  // 月份切换时整块重建，避免残留动画
    }

    /// 圆盘统一直径(写过日记的那天 / 今天都用同样大小,只在材质 tint 上区分)。
    private static let diskSize: CGFloat = 30

    @ViewBuilder
    private func dayCell(for date: Date) -> some View {
        let startOfDate = calendar.startOfDay(for: date)
        let mood = moodByDay[startOfDate]
        let isToday = calendar.isDateInToday(date)
        let isFuture = startOfDate > calendar.startOfDay(for: Date())
        let hasEntry = mood != nil
        let day = calendar.component(.day, from: date)

        Button {
            guard hasEntry, !isFuture else { return }
            #if canImport(UIKit)
            HapticManager.shared.click()
            #endif
            onSelectDate(date)
        } label: {
            // 把 glass 直接挂在 Text 上 —— `.glassEffect` 的语义是"把材质放在被修饰视图后面",
            // 内容(数字)天然就在材质前面。之前用 .background/ZStack 都不稳是因为
            // 当被修饰视图是 Color.clear 时 glass 会塌成色块。挂在 Text 上没这个问题。
            dayContent(day: day, isToday: isToday, isFuture: isFuture, hasEntry: hasEntry, mood: mood)
                .overlay {
                    if isToday {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.2)
                            .frame(width: Self.diskSize, height: Self.diskSize)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Self.cellHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasEntry || isFuture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: date, mood: mood, isToday: isToday))
        .accessibilityAddTraits(isToday ? [.isSelected] : [])
    }

    /// 数字本身 + 玻璃 disc(条件性套上去)。两个分支共用同一段 Text 以保证 layout 一致。
    @ViewBuilder
    private func dayContent(
        day: Int,
        isToday: Bool,
        isFuture: Bool,
        hasEntry: Bool,
        mood: Double?
    ) -> some View {
        let text = Text("\(day)")
            .font(.system(size: 13, weight: isToday ? .bold : .regular))
            .foregroundColor(isFuture ? .secondary.opacity(0.4) : .primary)
            .frame(width: Self.diskSize, height: Self.diskSize)

        if hasEntry || isToday {
            text.liquidGlassCircle(
                tint: mood.map { Color.moodSpectrum(value: $0) },
                tintStrength: 0.20
            )
        } else {
            text
        }
    }

    private func accessibilityLabel(for date: Date, mood: Double?, isToday: Bool) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        var base = f.string(from: date)
        if isToday {
            base += "，" + NSLocalizedString("今天", comment: "Today a11y")
        }
        if let mood {
            base += "，" + String(format: NSLocalizedString("情绪 %d 分，点击查看当天日记", comment: "Mood score a11y"), Int(mood * 100))
        }
        return base
    }

    // MARK: Cache management

    private func rebuildCachesIfNeeded() {
        let identity = hashCells()
        guard identity != lastCellsIdentity else {
            ensureDaysCached()
            return
        }
        lastCellsIdentity = identity
        var dict: [Date: Double] = [:]
        dict.reserveCapacity(cells.count)
        for cell in cells {
            dict[calendar.startOfDay(for: cell.date)] = cell.mood
        }
        moodByDay = dict
        daysByMonthKey.removeAll(keepingCapacity: true)
        ensureDaysCached()
    }

    private func ensureDaysCached() {
        let key = monthKey(displayedMonth)
        if daysByMonthKey[key] == nil {
            daysByMonthKey[key] = makeDays(for: displayedMonth)
        }
    }

    /// 纯读缓存。cache miss 时 *不* 写入——view body 里写 @State 会触发
    /// "Modifying state during view update"。写入由 `ensureDaysCached()` 统一从
    /// onAppear / onChange 生命周期钩子里处理。
    private func days(for month: Date) -> [Date?] {
        if let cached = daysByMonthKey[monthKey(month)] { return cached }
        return makeDays(for: month)
    }

    private func hashCells() -> Int {
        var hasher = Hasher()
        hasher.combine(cells.count)
        hasher.combine(cells.first?.date)
        hasher.combine(cells.last?.date)
        hasher.combine(cells.first?.mood)
        hasher.combine(cells.last?.mood)
        return hasher.finalize()
    }

    // MARK: Month helpers

    private func changeMonth(by value: Int) {
        guard let m = calendar.date(byAdding: .month, value: value, to: displayedMonth) else { return }
        #if canImport(UIKit)
        HapticManager.shared.click()
        #endif
        displayedMonth = m
    }

    private var canGoBack: Bool {
        guard let earliest = cells.min(by: { $0.date < $1.date })?.date else { return true }
        guard let currentStart = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) else { return true }
        return earliest < currentStart
    }

    private var canGoForward: Bool {
        guard let next = calendar.date(byAdding: .month, value: 1, to: displayedMonth),
              let nextStart = calendar.date(from: calendar.dateComponents([.year, .month], from: next)) else { return false }
        return nextStart <= Date()
    }

    private func monthKey(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private func makeDays(for month: Date) -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) else {
            return []
        }
        var days: [Date?] = []
        days.reserveCapacity(42)
        let weekdayOfFirst = calendar.component(.weekday, from: firstOfMonth)
        let weekdayIndex = (weekdayOfFirst - calendar.firstWeekday + 7) % 7
        days.append(contentsOf: Array(repeating: nil, count: weekdayIndex))
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) {
                days.append(date)
            }
        }
        return days
    }

    private func monthYearString(for date: Date) -> String {
        Self.monthYearFormatter.string(from: date)
    }

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMM")
        return f
    }()
}
