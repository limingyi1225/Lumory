import SwiftUI
import CoreData

// MARK: - Point detail sheet (点击图表点时弹出)

struct PointDetailSheet: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    let point: InsightsEngine.MoodPoint

    @State private var entries: [DiaryEntry] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries, id: \.objectID) { entry in
                    NavigationLink(value: entry) {
                        DiaryEntryRow(entry: entry)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if entries.isEmpty {
                    Text(NSLocalizedString("该时段没有日记", comment: "No entries for bucket"))
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(dateLabel)
            .navigationDestination(for: DiaryEntry.self) { entry in
                DiaryDetailView(entry: entry, startInEditMode: false)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("关闭", comment: "Close")) { dismiss() }
                }
            }
            .onAppear(perform: fetch)
        }
    }

    private var dateLabel: String {
        point.date.formatted(date: .abbreviated, time: .omitted)
    }

    private func fetch() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: point.date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND date < %@",
            dayStart as NSDate,
            dayEnd as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
        entries = (try? viewContext.fetch(request)) ?? []
    }
}
