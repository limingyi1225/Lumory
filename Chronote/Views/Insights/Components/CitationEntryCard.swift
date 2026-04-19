import SwiftUI
import CoreData

// MARK: - CitationEntryCard
//
// Ask Your Past 里 AI 气泡下方的"参考日记"小卡。只显示日期 + summary 前两行，
// 点击进入完整 DiaryDetailView。在 CoreData context 上轻量 fetch 单条，
// 不用 FetchRequest 以避免在滚动聊天列表里触发重 query。

struct CitationEntryCard: View {
    let entryId: UUID
    @Environment(\.managedObjectContext) private var viewContext

    @State private var entry: DiaryEntry?
    @State private var resolvedMissing = false

    var body: some View {
        Group {
            if let entry {
                NavigationLink {
                    DiaryDetailView(entry: entry, startInEditMode: false)
                } label: {
                    content(for: entry)
                }
                .buttonStyle(.plain)
            } else if resolvedMissing {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.square.dashed")
                        .foregroundColor(.secondary)
                    Text(NSLocalizedString("原日记已不可用", comment: "Missing citation"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else {
                skeleton
            }
        }
        .onAppear(perform: fetch)
        // `.id(entryId)`：LazyVStack 会在滚动时复用 View 实例，同一 View 被 rebind 到不同 entryId
        // 时 `onAppear` 不保证再次触发，原 `guard entry == nil` 会让卡片继续显示旧 entry。
        // 加 id 强制 SwiftUI 把不同 entryId 视作不同 View，重走 onAppear + fetch 周期。
        .id(entryId)
    }

    // 复用一个静态 formatter——以前每次 dateLabel 调用都 new 一个，滚动列表里非常浪费。
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
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

    private var skeleton: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.secondary.opacity(0.06))
            .frame(height: 46)
    }

    // MARK: Fetch

    private func fetch() {
        // 只有当 entry 还没 fetch 或者对应的是老的 entryId 时才 fetch
        if let current = entry, current.id == entryId { return }
        entry = nil
        resolvedMissing = false
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        // UUID 不符合 CVarArg —— 必须桥接到 NSUUID，否则运行时抛 cast failure。
        request.predicate = NSPredicate(format: "id == %@", entryId as NSUUID)
        request.fetchLimit = 1
        if let found = try? viewContext.fetch(request).first {
            entry = found
        } else {
            resolvedMissing = true
        }
    }

    private func dateLabel(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }
}
