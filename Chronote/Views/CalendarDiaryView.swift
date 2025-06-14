import SwiftUI
import CoreData
#if canImport(UIKit)
import UIKit
#endif

struct CalendarDiaryView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)],
        animation: .default)
    private var entries: FetchedResults<DiaryEntry>
    
    // AI 服务（从 DiaryStore 中提取）
    private let aiService = AppleRecognitionService(openAIApiKey: AppSecrets.openAIKey)
    
    @State private var displayedMonth: Date = Date()
    @State private var selectedDate: Date? = nil
    @AppStorage("appLanguage") private var appLanguage: String = Locale.current.identifier
    
    // 情绪报告相关状态
    @State private var reportStartDate: Date
    @State private var reportEndDate: Date = Date()
    @State private var report: String? = nil
    @State private var isGeneratingReport = false
    
    // 滑动动画相关状态
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private let calendar = Calendar.current

    // 在 init 中初始化 reportStartDate，确保在视图构建前完成
    init() {
        let context = PersistenceController.shared.container.viewContext
        let fetchRequest: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: true)]
        fetchRequest.fetchLimit = 1
        do {
            if let firstEntry = try context.fetch(fetchRequest).first {
                _reportStartDate = State(initialValue: firstEntry.date ?? Date())
            } else {
                _reportStartDate = State(initialValue: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
            }
        } catch {
            _reportStartDate = State(initialValue: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
        }
    }

    // MARK: - 辅助函数
    
    private func entries(on date: Date) -> [DiaryEntry] {
        entries.filter { calendar.isDate($0.wrappedDate, inSameDayAs: date) }
    }
    
    private func entries(in range: ClosedRange<Date>) -> [DiaryEntry] {
        entries.filter { range.contains($0.wrappedDate) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 月份切换
                HStack(spacing: 12) {
                    Button(action: { changeMonth(by: -1) }) {
                        Image(systemName: "chevron.left")
                            .font(.title3)
                    }
                    Text(monthYearString(for: displayedMonth))
                        .font(.headline)
                    Button(action: { changeMonth(by: 1) }) {
                        Image(systemName: "chevron.right")
                            .font(.title3)
                    }
                }
                .padding(.horizontal)

                // 日历网格 - 添加滑动手势
                GeometryReader { geometry in
                    let screenWidth = geometry.size.width
                    
                    HStack(spacing: 0) {
                        // 上个月
                        monthGrid(for: previousMonth())
                            .frame(width: screenWidth)
                        
                        // 当前月
                        monthGrid(for: displayedMonth)
                            .frame(width: screenWidth)
                        
                        // 下个月
                        monthGrid(for: nextMonth())
                            .frame(width: screenWidth)
                    }
                    .offset(x: -screenWidth + dragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                isDragging = true
                                dragOffset = value.translation.width
                            }
                            .onEnded { value in
                                isDragging = false
                                let threshold: CGFloat = screenWidth * 0.25
                                
                                // 直接切换月份，无平滑过渡
                                if value.translation.width > threshold {
                                    // 向右滑动，显示上个月
#if canImport(UIKit)
                                    HapticManager.shared.click()
#endif
                                    changeMonth(by: -1)
                                    dragOffset = 0
                                } else if value.translation.width < -threshold {
                                    // 向左滑动，显示下个月
#if canImport(UIKit)
                                    HapticManager.shared.click()
#endif
                                    changeMonth(by: 1)
                                    dragOffset = 0
                                } else {
                                    // 回弹到原位置
                                    dragOffset = 0
                                }
                            }
                    )
                }
                .frame(height: 280)
                .clipped()

                Divider()

                // 选中日期显示与情绪报告
                VStack(spacing: 16) {
                    // 选中日期的日记
                    if let selected = selectedDate {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(String(format: NSLocalizedString("%@ 的日记", comment: "Journal for date"), DateFormatter.localizedString(from: selected, dateStyle: .long, timeStyle: .none)))
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            ForEach(entries(on: selected)) { entry in
                                NavigationLink(destination: DiaryDetailView(entry: entry)) {
                                    DiaryRow(entry: entry)
                                }
                                .buttonStyle(.plain)
                            }
                            
                            if entries(on: selected).isEmpty {
                                Text(NSLocalizedString("当日暂无日记", comment: "No entries for this day"))
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    
                    // 情绪报告区域
                    VStack(alignment: .leading, spacing: 12) {
                        Text(NSLocalizedString("情绪报告", comment: "Emotional report"))
                            .font(.headline)
                        
                        VStack(spacing: 8) {
                            // 计算选定区间内的日记篇数，确保范围合法
                            let selectedEntriesCount = reportStartDate <= reportEndDate ? entries(in: reportStartDate...reportEndDate).count : 0
                            HStack {
                                DatePicker("开始", selection: $reportStartDate, displayedComponents: .date)
                                    .labelsHidden()
                                Text(NSLocalizedString("至", comment: "To"))
                                    .foregroundColor(.secondary)
                                DatePicker("结束", selection: $reportEndDate, displayedComponents: .date)
                                    .labelsHidden()
                            }
                            
                            // 生成报告按钮，需至少3篇日记才可点击
                            Button {
                                Task { await generateReport() }
                            } label: {
                                Text(NSLocalizedString("生成报告", comment: "Generate report"))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isGeneratingReport || selectedEntriesCount < 3)
                            
                            // 提示：篇数不足时显示
                            if selectedEntriesCount < 3 {
                                Text(NSLocalizedString("至少需要3篇日记才能生成报告。", comment: "At least 3 entries required"))
                                    .font(.caption)
                                    .foregroundColor(.secondary.opacity(0.7))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        
                        // 报告框：仅在 report 不为 nil 时展示，stream 期间显示文本，初始无内容时显示 loader
                        if let text = report {
                            Group {
                                if text.isEmpty {
                                    DotsLoadingView()
                                        .frame(maxWidth: .infinity, minHeight: 100)
                                } else {
                                    Text(text)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(12)
                                }
                            }
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .animation(AnimationConfig.smoothTransition, value: text)
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
        }
        .navigationTitle(NSLocalizedString("日历视图", comment: "Calendar view"))
    }

    // MARK: - Helpers
    private func changeMonth(by value: Int) {
        if let newMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) {
            // displayedMonth change will trigger view update.
            // The animation is now handled by the .onEnded block's withAnimation.
            displayedMonth = newMonth
            selectedDate = nil
        }
    }
    
    private func previousMonth() -> Date {
        return calendar.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
    }
    
    private func nextMonth() -> Date {
        return calendar.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
    }
    
    @ViewBuilder
    private func monthGrid(for date: Date) -> some View {
        let days = makeDays(for: date)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
            ForEach(Array(days.enumerated()), id: \.0) { idx, day in
                if let day {
                    dayCell(for: day)
                } else {
                    Color.clear.frame(height: 40)
                }
            }
        }
        .padding(.horizontal)
    }

    private func monthYearString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: date)
    }

    private func makeDays(for month: Date? = nil) -> [Date?] {
        let targetMonth = month ?? displayedMonth
        guard let range = calendar.range(of: .day, in: .month, for: targetMonth),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: targetMonth)) else {
            return []
        }
        var days: [Date?] = []
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

    // 新增辅助函数：根据 moodValue 计算颜色（与 DiaryEntry 中逻辑类似）
    private func averageMoodColor(for entries: [DiaryEntry]) -> Color {
        if entries.isEmpty {
            return .clear
        }
        // 使用最新的 moodSpectrum 生成颜色
        let averageMood = entries.reduce(0) { $0 + $1.moodValue } / Double(entries.count)
        return Color.moodSpectrum(value: averageMood)
    }

    @ViewBuilder
    private func dayCell(for date: Date) -> some View {
        let entries = entries(on: date)
        let displayMoodColor = averageMoodColor(for: entries)
        let dayNumber = calendar.component(.day, from: date)

        VStack {
            Text("\(dayNumber)")
                .font(.subheadline)
                .fontWeight(calendar.isDateInToday(date) ? .bold : .regular)
                .foregroundColor(calendar.isDateInToday(date)
                    ? (colorScheme == .dark ? .white : .black)
                    : .primary)
                .frame(maxWidth: .infinity)
                .padding(6)
                .background(
                    Circle().fill(displayMoodColor.opacity(entries.isEmpty ? 0 : 0.7))
                 )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedDate = date
        }
        .frame(height: 40)
    }

    @MainActor
    private func generateReport() async {
        guard reportStartDate <= reportEndDate else { return }
        isGeneratingReport = true
        let range = reportStartDate...reportEndDate
        let entries = entries(in: range)
        // 空数据校验
        guard !entries.isEmpty else {
            report = NSLocalizedString("该时间段内没有日记数据。", comment: "生成报告 空数据提示")
            isGeneratingReport = false
            return
        }
        // 篇数校验：至少3篇
        guard entries.count >= 3 else {
            report = NSLocalizedString("至少需要3篇日记才能生成报告。", comment: "生成报告 篇数校验提示")
            isGeneratingReport = false
            return
        }
        // 使用流式生成报告，逐步更新 UI
        report = ""
        await aiService.generateReport(entries: entries) { chunk in
            Task { @MainActor in
                print("收到chunk: \"\(chunk)\"")
                report = (report ?? "") + chunk
            }
        }
        isGeneratingReport = false
        #if canImport(UIKit)
        HapticManager.shared.click()
        #endif
    }
}

// 插入自定义三点呼吸灯组件，用于报告开始流式前的加载指示
struct DotsLoadingView: View {
    @State private var animate = [false, false, false]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 8, height: 8)
                    .opacity(animate[index] ? 1.0 : 0.3)
                    .scaleEffect(animate[index] ? 1.0 : 0.6)
                    .animation(
                        AnimationConfig.breathingAnimation
                            .delay(Double(index) * 0.2),
                        value: animate[index]
                    )
            }
        }
        .onAppear {
            for i in animate.indices {
                animate[i] = true
            }
        }
    }
}

#Preview {
    CalendarDiaryView()
        .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
}

// 处理段落分割的视图组件
struct ParagraphView: View {
    let text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let paragraphs = text.components(separatedBy: "\n\n")
            ForEach(paragraphs.indices, id: \.self) { index in
                let paragraph = paragraphs[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if !paragraph.isEmpty {
                    Text(paragraph)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear {
            print("=== ParagraphView 原始文本 ===")
            print(text)
            print("=== ParagraphView 段落分割结果 ===")
            let paragraphs = text.components(separatedBy: "\n\n")
            for (index, para) in paragraphs.enumerated() {
                print("段落 \(index): \"\(para)\"")
            }
            print("=== ParagraphView 结束 ===")
        }
    }
} 