import SwiftUI
import CoreData

// MARK: - HomeDesignPreviewView
//
// 临时 UI 预览容器：顶部 segmented picker，切 4 个候选首页设计。
// 用真数据（真实 DiaryEntry）渲染，但不接写作/录音功能 —— 纯视觉比较。

struct HomeDesignPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
    ) private var entries: FetchedResults<DiaryEntry>

    @State private var selected: Design = .a

    enum Design: String, CaseIterable, Identifiable {
        case a = "A · 晨信"
        case b = "B · 时间线"
        case c = "C · Studio"
        case d = "D · Soft"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selected) {
                    ForEach(Design.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                Group {
                    switch selected {
                    case .a: DesignAMorningLetter(entries: Array(entries))
                    case .b: DesignBTimeline(entries: Array(entries))
                    case .c: DesignCStudio(entries: Array(entries))
                    case .d: DesignDSoftJournal(entries: Array(entries))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.2), value: selected)
            }
            .navigationTitle("首页 UI 预览")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Shared preview helpers

enum DesignPreviewHelpers {
    static func avgMood(_ entries: [DiaryEntry], lookback: Int = 7) -> Double {
        let recent = entries.prefix(lookback).map(\.moodValue)
        guard !recent.isEmpty else { return 0.5 }
        return recent.reduce(0, +) / Double(recent.count)
    }

    static func streak(_ entries: [DiaryEntry]) -> Int {
        let cal = Calendar.current
        let days = Set(entries.compactMap { $0.date.map { cal.startOfDay(for: $0) } })
        var streak = 0
        var cursor = cal.startOfDay(for: Date())
        while days.contains(cursor) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    static func moodEmoji(_ v: Double) -> String {
        switch v {
        case ..<0.2: return "😞"
        case ..<0.4: return "😕"
        case ..<0.6: return "😐"
        case ..<0.8: return "🙂"
        default:     return "😊"
        }
    }

    static func fullWeekday(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    static func shortWeekday(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    static func bigDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func relativeDateLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        if days < 7 { return shortWeekday(date) }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }
}
