import SwiftUI
import CoreData

// MARK: - CitationEntryCard
//
// Ask Your Past 里 AI 气泡下方的"参考日记"小卡。只显示日期 + summary 前两行，
// 点击进入完整 DiaryDetailView。上游 CitationEntryList 会按 id IN 一次批量 fetch，
// 避免展开 N 条引用时做 N 次主线程 round-trip。

struct CitationEntryList: View {
    let ids: [UUID]
    @Environment(\.managedObjectContext) private var viewContext

    @State private var entriesByID: [UUID: DiaryEntry] = [:]
    @State private var missingIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 8) {
            ForEach(ids, id: \.self) { entryID in
                if let entry = entriesByID[entryID] {
                    CitationEntryCard(entry: entry)
                } else if missingIDs.contains(entryID) {
                    MissingCitationCard()
                } else {
                    CitationSkeletonCard()
                }
            }
        }
        .task(id: ids) {
            await fetchEntries()
        }
    }

    @MainActor
    private func fetchEntries() async {
        guard !ids.isEmpty else {
            entriesByID = [:]
            missingIDs = []
            return
        }
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", ids.map { $0 as NSUUID })
        guard let entries = try? viewContext.fetch(request) else {
            entriesByID = [:]
            missingIDs = Set(ids)
            return
        }
        entriesByID = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            guard let id = entry.id else { return nil }
            return (id, entry)
        })
        missingIDs = Set(ids).subtracting(entriesByID.keys)
    }
}

struct CitationEntryCard: View {
    let entry: DiaryEntry

    var body: some View {
        NavigationLink {
            DiaryDetailView(entry: entry, startInEditMode: false)
        } label: {
            content(for: entry)
        }
        .buttonStyle(.plain)
    }

    // 复用一个静态 formatter——以前每次 dateLabel 调用都 new 一个，滚动列表里非常浪费。
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    // MARK: Content

    private func content(for entry: DiaryEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.moodSpectrum(value: entry.moodValue))
                        .frame(width: 8, height: 8)
                    Text(dateLabel(entry.date ?? Date()))
                        .font(.caption.weight(.medium))
                        .foregroundColor(.primary)
                }
                Text(entry.displayText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func dateLabel(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }
}

private struct MissingCitationCard: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.square.dashed")
                .foregroundColor(.secondary)
            Text(NSLocalizedString("原日记已不可用", comment: "Missing citation"))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CitationSkeletonCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.secondary.opacity(0.06))
            .frame(height: 46)
    }
}
