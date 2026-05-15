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
        request.predicate = NSPredicate(format: "id IN %@", ids as NSArray)
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
        .buttonStyle(PressableScaleButtonStyle())
    }

    // 日期 label 复用 `LumoryDateFormatters.mediumDate` 共享实例。

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
        // 与项目里其他列表卡(ThemeMergeIntoSheet / SuggestionTargetPickerSheet / ThemeAliasManagement
        // pendingCard)统一 liquidGlass + 14pt 圆角,不再用 flat fill 显得 AI 引用比真日记 row "次级"。
        .liquidGlassCard(cornerRadius: 14, interactive: true)
    }

    private func dateLabel(_ date: Date) -> String {
        LumoryDateFormatters.mediumDate.string(from: date)
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
        .liquidGlassCard(cornerRadius: 14, interactive: false)
    }
}

private struct CitationSkeletonCard: View {
    var body: some View {
        // skeleton 也走 liquidGlass(无 tint)—— 加载完成后切换到带内容的同尺寸卡,过渡更自然。
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.secondary.opacity(0.06))
            .frame(height: 46)
    }
}
