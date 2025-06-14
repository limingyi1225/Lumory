import SwiftUI
import CoreData
#if canImport(UIKit)
import UIKit
#endif

struct CalendarDiaryViewOptimized: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)],
        animation: .default)
    private var entries: FetchedResults<DiaryEntry>
    
    // AI Service
    private let aiService = OpenAIService(apiKey: AppSecrets.openAIKey)
    
    @State private var displayedMonth: Date = Date()
    @State private var selectedDate: Date? = nil
    @AppStorage("appLanguage") private var appLanguage: String = Locale.current.identifier
    
    // Report related state
    @State private var reportStartDate: Date
    @State private var reportEndDate: Date = Date()
    @State private var report: String? = nil
    @State private var isGeneratingReport = false
    
    // Swipe animation state
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    
    // Optimized cache for performance
    @State private var entriesCache: [Date: [DiaryEntry]] = [:]
    @State private var monthCache: [Date: [Date?]] = [:]
    @State private var lastCacheUpdate: Date = Date.distantPast
    
    private let calendar = Calendar.current
    private let hapticManager = HapticManager.shared
    
    // Initialize reportStartDate
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
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Month switcher
                monthNavigationHeader
                
                // Calendar grid with swipe gesture
                calendarGrid
                    .frame(height: 280)
                    .clipped()
                
                Divider()
                
                // Selected date and report section
                VStack(spacing: 16) {
                    selectedDateSection
                    reportSection
                }
                .padding()
                
                Color.clear.frame(height: 40)
            }
        }
        .onAppear {
            cacheEntries()
        }
        .onChange(of: entries.count) { _, _ in
            // Only update cache if significant time has passed to reduce frequent updates
            let now = Date()
            if now.timeIntervalSince(lastCacheUpdate) > 1.0 {
                cacheEntries()
                lastCacheUpdate = now
            }
        }
    }
    
    // MARK: - Subviews
    
    private var monthNavigationHeader: some View {
        HStack(spacing: 12) {
            Button(action: { changeMonth(by: -1) }) {
                Image(systemName: "chevron.left")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            
            Text(monthYearString(for: displayedMonth))
                .font(.headline)
            
            Button(action: { changeMonth(by: 1) }) {
                Image(systemName: "chevron.right")
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
    
    private var calendarGrid: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            
            HStack(spacing: 0) {
                // Previous month
                OptimizedMonthGrid(
                    month: previousMonth(),
                    days: getDaysForMonth(previousMonth()),
                    entriesCache: entriesCache,
                    selectedDate: $selectedDate,
                    calendar: calendar,
                    colorScheme: colorScheme
                )
                .frame(width: screenWidth)
                .id(previousMonth())
                
                // Current month
                OptimizedMonthGrid(
                    month: displayedMonth,
                    days: getDaysForMonth(displayedMonth),
                    entriesCache: entriesCache,
                    selectedDate: $selectedDate,
                    calendar: calendar,
                    colorScheme: colorScheme
                )
                .frame(width: screenWidth)
                .id(displayedMonth)
                
                // Next month
                OptimizedMonthGrid(
                    month: nextMonth(),
                    days: getDaysForMonth(nextMonth()),
                    entriesCache: entriesCache,
                    selectedDate: $selectedDate,
                    calendar: calendar,
                    colorScheme: colorScheme
                )
                .frame(width: screenWidth)
                .id(nextMonth())
            }
            .offset(x: -screenWidth + dragOffset)
            .animation(isDragging ? nil : .interactiveSpring(), value: dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        dragOffset = value.translation.width
                    }
                    .onEnded { value in
                        isDragging = false
                        let threshold: CGFloat = screenWidth * 0.25
                        
                        if value.translation.width > threshold {
                            hapticManager.click()
                            changeMonth(by: -1)
                        } else if value.translation.width < -threshold {
                            hapticManager.click()
                            changeMonth(by: 1)
                        }
                        dragOffset = 0
                    }
            )
        }
    }
    
    @ViewBuilder
    private var selectedDateSection: some View {
        if let selected = selectedDate {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(format: NSLocalizedString("%@ 的日记", comment: ""), 
                           DateFormatter.localizedString(from: selected, dateStyle: .long, timeStyle: .none)))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                if let dayEntries = entriesCache[calendar.startOfDay(for: selected)], !dayEntries.isEmpty {
                    ForEach(dayEntries) { entry in
                        NavigationLink(destination: DiaryDetailView(entry: entry)) {
                            OptimizedDiaryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text(NSLocalizedString("当日暂无日记", comment: ""))
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .transition(.asymmetric(
                insertion: .scale.combined(with: .opacity),
                removal: .scale.combined(with: .opacity)
            ))
        }
    }
    
    private var reportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("情绪报告", comment: ""))
                .font(.headline)
            
            VStack(spacing: 8) {
                // Date range picker
                HStack {
                    DatePicker("", selection: $reportStartDate, displayedComponents: .date)
                        .labelsHidden()
                    
                    Text(NSLocalizedString("至", comment: ""))
                        .foregroundColor(.secondary)
                    
                    DatePicker("", selection: $reportEndDate, displayedComponents: .date)
                        .labelsHidden()
                }
                
                let selectedEntriesCount = getEntriesCount(from: reportStartDate, to: reportEndDate)
                
                // Generate button
                Button {
                    Task { await generateReport() }
                } label: {
                    if isGeneratingReport {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Text(NSLocalizedString("生成报告", comment: ""))
                    }
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.borderedProminent)
                .disabled(isGeneratingReport || selectedEntriesCount < 3)
                
                // Hint
                if selectedEntriesCount < 3 {
                    Text(NSLocalizedString("至少需要3篇日记才能生成报告。", comment: ""))
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            
            // Report display
            if let text = report {
                Group {
                    if text.isEmpty {
                        BreathingDots()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else {
                        ParagraphView(text: text)
                            .padding()
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .transition(.asymmetric(
                    insertion: .push(from: .bottom).combined(with: .opacity),
                    removal: .push(from: .top).combined(with: .opacity)
                ))
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Helper Methods
    
    private func cacheEntries() {
        entriesCache.removeAll()
        for entry in entries {
            let dayStart = calendar.startOfDay(for: entry.wrappedDate)
            if entriesCache[dayStart] == nil {
                entriesCache[dayStart] = []
            }
            entriesCache[dayStart]?.append(entry)
        }
    }
    
    private func getDaysForMonth(_ month: Date) -> [Date?] {
        if let cached = monthCache[month] {
            return cached
        }
        let days = makeDays(for: month)
        monthCache[month] = days
        return days
    }
    
    private func makeDays(for month: Date) -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) else {
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
    
    private func monthYearString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: date)
    }
    
    private func changeMonth(by value: Int) {
        guard let newMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) else { return }
        displayedMonth = newMonth
    }
    
    private func previousMonth() -> Date {
        calendar.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
    }
    
    private func nextMonth() -> Date {
        calendar.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
    }
    
    private func getEntriesCount(from startDate: Date, to endDate: Date) -> Int {
        guard startDate <= endDate else { return 0 }
        
        return entries.filter { entry in
            entry.wrappedDate >= startDate && entry.wrappedDate <= endDate
        }.count
    }
    
    @MainActor
    private func generateReport() async {
        guard reportStartDate <= reportEndDate else { return }
        isGeneratingReport = true
        
        let filteredEntries = entries.filter { entry in
            entry.wrappedDate >= reportStartDate && entry.wrappedDate <= reportEndDate
        }
        
        guard filteredEntries.count >= 3 else {
            report = NSLocalizedString("至少需要3篇日记才能生成报告。", comment: "")
            isGeneratingReport = false
            return
        }
        
        report = ""
        await aiService.generateReport(entries: Array(filteredEntries)) { chunk in
            Task { @MainActor in
                report = (report ?? "") + chunk
            }
        }
        
        isGeneratingReport = false
        hapticManager.click()
    }
}

// MARK: - Optimized Month Grid
struct OptimizedMonthGrid: View {
    let month: Date
    let days: [Date?]
    let entriesCache: [Date: [DiaryEntry]]
    @Binding var selectedDate: Date?
    let calendar: Calendar
    let colorScheme: ColorScheme
    
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private let weekdaySymbols: [String]
    
    init(month: Date, days: [Date?], entriesCache: [Date: [DiaryEntry]], 
         selectedDate: Binding<Date?>, calendar: Calendar, colorScheme: ColorScheme) {
        self.month = month
        self.days = days
        self.entriesCache = entriesCache
        self._selectedDate = selectedDate
        self.calendar = calendar
        self.colorScheme = colorScheme
        
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        self.weekdaySymbols = formatter.shortWeekdaySymbols
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Weekday headers
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal)
            
            // Days grid - optimized for Mac Catalyst
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(days.indices, id: \.self) { index in
                    if let date = days[index] {
                        OptimizedDayCell(
                            date: date,
                            entries: entriesCache[calendar.startOfDay(for: date)] ?? [],
                            isSelected: calendar.isDate(date, inSameDayAs: selectedDate ?? Date()),
                            isToday: calendar.isDateInToday(date),
                            colorScheme: colorScheme
                        ) {
                            selectedDate = date
                        }
                        .reduceRedraws(date) // Use our performance optimization
                    } else {
                        Color.clear
                            .frame(height: 40)
                            .reduceRedraws(index) // Reduce redraws for empty cells too
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Optimized Day Cell
struct OptimizedDayCell: View {
    let date: Date
    let entries: [DiaryEntry]
    let isSelected: Bool
    let isToday: Bool
    let colorScheme: ColorScheme
    let onTap: () -> Void
    
    private var averageMoodColor: Color {
        guard !entries.isEmpty else { return .clear }
        let averageMood = entries.reduce(0) { $0 + $1.moodValue } / Double(entries.count)
        return Color.moodSpectrum(value: averageMood)
    }
    
    var body: some View {
        Text("\(Calendar.current.component(.day, from: date))")
            .font(.subheadline)
            .fontWeight(isToday ? .bold : .regular)
            .foregroundColor(isToday ? (colorScheme == .dark ? .white : .black) : .primary)
            .frame(maxWidth: .infinity)
            .padding(6)
            .background(
                Circle()
                    .fill(averageMoodColor.opacity(entries.isEmpty ? 0 : 0.7))
                    .overlay(
                        Circle()
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .frame(height: 40)
    }
}

// MARK: - Optimized Diary Row
struct OptimizedDiaryRow: View {
    let entry: DiaryEntry
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Mood indicator
            Circle()
                .fill(Color.moodSpectrum(value: entry.moodValue))
                .frame(width: 12, height: 12)
                .padding(.top, 4)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayText)
                    .font(.system(size: 15))
                    .lineLimit(2)
                    .foregroundColor(.primary)
                
                HStack {
                    Text(timeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if entry.audioFileName != nil {
                        Image(systemName: "waveform")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    
                    if !entry.imageFileNameArray.isEmpty {
                        Label("\(entry.imageFileNameArray.count)", systemImage: "photo")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
    
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: entry.wrappedDate)
    }
}

#Preview {
    CalendarDiaryViewOptimized()
        .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
}