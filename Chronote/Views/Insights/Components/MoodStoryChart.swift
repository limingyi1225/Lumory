import SwiftUI
import Charts

// MARK: - MoodStoryChart
//
// Insights Dashboard 第一块。Swift Charts 折线图 + 点位随心情谱系渐变。
// 数据从 InsightsEngine.moodSeries 来；empty / loading / loaded 三态。
// 选中逻辑对齐 bucket 粒度：day/week/month 都用 bucket 起点比较，避免周/月图点不上。

struct MoodStoryChart: View {
    let points: [InsightsEngine.MoodPoint]
    let bucket: InsightsEngine.Bucket
    let isLoading: Bool
    let onTapPoint: (InsightsEngine.MoodPoint) -> Void

    @State private var selectedPointID: Date?
    @State private var rawSelectionDate: Date?

    init(
        points: [InsightsEngine.MoodPoint],
        bucket: InsightsEngine.Bucket = .day,
        isLoading: Bool,
        onTapPoint: @escaping (InsightsEngine.MoodPoint) -> Void
    ) {
        self.points = points
        self.bucket = bucket
        self.isLoading = isLoading
        self.onTapPoint = onTapPoint
    }

    // MARK: - Derived

    private var stats: (avg: Double, delta: Double?)? {
        guard !points.isEmpty else { return nil }
        let avg = points.reduce(0) { $0 + $1.mood } / Double(points.count)
        let delta: Double?
        if points.count >= 2, let first = points.first?.mood, let last = points.last?.mood {
            delta = last - first
        } else {
            delta = nil
        }
        return (avg, delta)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Group {
                if isLoading && points.isEmpty {
                    skeletonChart
                } else if points.isEmpty {
                    emptyState
                } else {
                    chart
                        .accessibilityLabel(accessibilitySummary)
                }
            }
            .frame(height: 220)
        }
        .padding(16)
        .insightsCard()
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("情绪故事", comment: "Mood story title"))
                    .font(.headline)
                if let avg = stats?.avg {
                    Text(String(format: NSLocalizedString("平均情绪 %d", comment: "Avg mood out of 100"), Int(avg * 100)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if let delta = stats?.delta {
                deltaBadge(delta)
            }
        }
    }

    // MARK: Chart

    @ViewBuilder
    private var chart: some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("date", point.date),
                    y: .value("mood", point.mood)
                )
                .foregroundStyle(lineGradient)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                PointMark(
                    x: .value("date", point.date),
                    y: .value("mood", point.mood)
                )
                .symbolSize(point.entryCount > 1 ? 80 : 50)
                .foregroundStyle(Color.moodSpectrum(value: point.mood))
            }

            RuleMark(y: .value("neutral", 0.5))
                .foregroundStyle(.secondary.opacity(0.25))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            if let selectedPoint {
                // 只画虚线 RuleMark + 把 annotation 挂在它顶上 —— 不再加大 PointMark,
                // 那个 140-size 的点视觉像"光晕",用户嫌重。
                RuleMark(x: .value("selected", selectedPoint.date))
                    .foregroundStyle(Color.moodSpectrum(value: selectedPoint.mood).opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(
                        position: .top,
                        alignment: .center,
                        spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        selectionTag(point: selectedPoint)
                    }
            }
        }
        .chartYScale(domain: 0...1)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 0.5, 1]) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(moodLabel(for: v))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                AxisGridLine().foregroundStyle(.secondary.opacity(0.1))
            }
        }
        // 用 Charts 自己的选择 API —— 和外层 ScrollView 协作，不会吞掉垂直滚动
        .chartXSelection(value: $rawSelectionDate)
        .onChange(of: rawSelectionDate) { _, newDate in
            guard let newDate, let match = closestPoint(to: newDate) else {
                selectedPointID = nil
                return
            }
            if selectedPointID != match.date {
                selectedPointID = match.date
                #if canImport(UIKit)
                HapticManager.shared.click()
                #endif
            }
        }
        .onTapGesture {
            if let point = selectedPoint {
                onTapPoint(point)
                selectedPointID = nil
                rawSelectionDate = nil
            }
        }
    }

    private var selectedPoint: InsightsEngine.MoodPoint? {
        guard let id = selectedPointID else { return nil }
        return points.first(where: { $0.date == id })
    }

    /// 选中点浮标:横向 pill,日期 + · + mood 色分数。
    /// 玻璃不带 tint(避免和 .primary 文字抢对比度),mood 色只走分数 + 外阴影,
    /// bucket 决定时间格式(日/周月/年月)。
    @ViewBuilder
    private func selectionTag(point: InsightsEngine.MoodPoint) -> some View {
        let mood = Color.moodSpectrum(value: point.mood)
        HStack(spacing: 8) {
            Text(formattedTagDate(point.date))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(mood)
            Text("·")
                .font(.footnote)
                .foregroundStyle(mood.opacity(0.55))
            Text(String(format: "%d", Int(point.mood * 100)))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(mood)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .liquidGlassCapsule()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                format: NSLocalizedString("%@,情绪 %d 分", comment: "A11y selected mood point"),
                formattedTagDate(point.date), Int(point.mood * 100)
            )
        )
    }

    private func formattedTagDate(_ date: Date) -> String {
        switch bucket {
        case .day:
            return Self.dayTagFormatter.string(from: date)
        case .week:
            // 周维度:显示该周的起止日期范围(eg. "Apr 7 – 13"),
            // 不是 weekTagFormatter 的单天日期 —— 那个会让用户以为只选中了一天。
            return Self.weekRangeString(from: date)
        case .month:
            return Self.monthTagFormatter.string(from: date)
        }
    }

    /// 把一个落在某周内的日期格式化成 "Apr 7 – 13" / "4月7日–13日"。
    private static func weekRangeString(from date: Date) -> String {
        let cal = Calendar.current
        guard let weekInterval = cal.dateInterval(of: .weekOfYear, for: date) else {
            return weekTagFormatter.string(from: date)
        }
        let start = weekInterval.start
        // .end 是下一周的开始,减 1 秒得到本周最后一天。
        let end = weekInterval.end.addingTimeInterval(-1)
        let startStr = weekTagFormatter.string(from: start)
        // 同月只显示日号 —— 用 dayOnlyFormatter 走 setLocalizedDateFormatFromTemplate("d"),
        // 这样 zh 会带"日"后缀("13日")、en 不会("13");不像之前 cal.component(.day) 给 raw int
        // → zh 显示"4月7日 – 13"丢"日"。
        let sameMonth = cal.component(.month, from: start) == cal.component(.month, from: end)
        let endStr = sameMonth
            ? dayOnlyFormatter.string(from: end)
            : weekTagFormatter.string(from: end)
        return "\(startStr) – \(endStr)"
    }

    /// 仅日号,locale-aware。zh-Hans → "13日";en → "13"。
    private static let dayOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d")
        return f
    }()

    private var lineGradient: LinearGradient {
        // 按路径上的每个点采样，颜色跟随 mood 真实变化
        let stops: [Gradient.Stop]
        if points.count <= 1 {
            let c = Color.moodSpectrum(value: points.first?.mood ?? 0.5)
            stops = [Gradient.Stop(color: c, location: 0), Gradient.Stop(color: c, location: 1)]
        } else {
            let span = max(0.0001, (points.last?.date.timeIntervalSince1970 ?? 0) - (points.first?.date.timeIntervalSince1970 ?? 0))
            let base = points.first?.date.timeIntervalSince1970 ?? 0
            stops = points.map {
                let loc = ($0.date.timeIntervalSince1970 - base) / span
                return Gradient.Stop(color: Color.moodSpectrum(value: $0.mood), location: loc)
            }
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    // MARK: Empty + Skeleton

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.secondary.opacity(0.5))
            Text(NSLocalizedString("这段时间还没有日记数据", comment: "Empty mood chart"))
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(NSLocalizedString("没有情绪数据", comment: "A11y: empty mood chart"))
    }

    private var skeletonChart: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.08))
            .overlay(ProgressView())
            .accessibilityLabel(NSLocalizedString("加载中", comment: "A11y: loading"))
    }

    // MARK: Helpers

    private func deltaBadge(_ delta: Double) -> some View {
        let positive = delta >= 0
        let label = String(format: "%@%.0f", positive ? "+" : "", delta * 100)
        let tint: Color = positive ? Color.moodSpectrum(value: 0.85) : Color.moodSpectrum(value: 0.15)
        return HStack(spacing: 2) {
            Image(systemName: positive ? "arrow.up.right" : "arrow.down.right")
            Text(label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.14)))
        .accessibilityLabel(
            positive
            ? String(format: NSLocalizedString("情绪上升 %d 点", comment: "A11y mood up"), Int(abs(delta) * 100))
            : String(format: NSLocalizedString("情绪下降 %d 点", comment: "A11y mood down"), Int(abs(delta) * 100))
        )
    }

    private func moodLabel(for v: Double) -> String {
        switch v {
        case 0: return NSLocalizedString("低落", comment: "Mood low")
        case 0.5: return NSLocalizedString("平静", comment: "Mood neutral")
        case 1: return NSLocalizedString("开心", comment: "Mood high")
        default: return ""
        }
    }

    /// bucket-aware closest-point lookup：把目标日期和每个点都归一到同一个时间标尺上比大小。
    private func closestPoint(to date: Date) -> InsightsEngine.MoodPoint? {
        points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
    }

    private var accessibilitySummary: String {
        guard let stats else {
            return NSLocalizedString("情绪折线图，暂无数据", comment: "A11y: mood chart empty")
        }
        let avgInt = Int(stats.avg * 100)
        if let delta = stats.delta {
            let sign = delta >= 0 ? NSLocalizedString("上升", comment: "up") : NSLocalizedString("下降", comment: "down")
            return String(
                format: NSLocalizedString("情绪折线图，%d 个数据点，平均 %d 分，整体%@ %d 点",
                                          comment: "A11y mood chart with trend"),
                points.count, avgInt, sign, Int(abs(delta) * 100)
            )
        }
        return String(
            format: NSLocalizedString("情绪折线图，%d 个数据点，平均 %d 分", comment: "A11y mood chart no trend"),
            points.count, avgInt
        )
    }

    /// 三个 bucket 各自一份模板,setLocalizedDateFormatFromTemplate 自动适配中英语序。
    private static let dayTagFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
    private static let weekTagFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
    private static let monthTagFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMM")
        return f
    }()
}
