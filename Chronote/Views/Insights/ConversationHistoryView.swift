import SwiftUI
import CoreData

// MARK: - ConversationHistoryView
//
// **wave12-3 历史回顾入口**。`AIConversation` entity 装两类 AI 输出历史:AskPast 一次次
// Q+A pair / NarrativeReader 一份份生成的报告。这个 view 是统一列表,左侧 Picker 切 kind,
// 点条进 read-only 详情。
//
// **入口**:在 `InsightsView` toolbar 加按钮(menu 里"历史回顾"item),只在已有任意 record
// 时才显示(避免空列表点进去)。
//
// **可读性**:列表条目展示 title(用户问题 / 报告时间范围)+ 相对时间 + kind 标签 + 截断 hint。
// 详情走 read-only 渲染,跟 AskPast / NarrativeReader 同款 markdown 排版,但**不能编辑 / 重生成**。

struct ConversationHistoryView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \AIConversation.createdAt, ascending: false)]
    ) private var conversations: FetchedResults<AIConversation>

    enum FilterMode: String, CaseIterable, Identifiable {
        case all
        case askPast
        case narrative
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return NSLocalizedString("全部", comment: "History filter: all")
            case .askPast: return NSLocalizedString("回顾", comment: "History filter: askPast")
            case .narrative: return NSLocalizedString("故事", comment: "History filter: narrative")
            }
        }
    }
    @State private var filter: FilterMode = .all

    var filtered: [AIConversation] {
        let all = Array(conversations)
        switch filter {
        case .all: return all
        case .askPast: return all.filter { $0.kindEnum == .askPast }
        case .narrative: return all.filter { $0.kindEnum == .narrative }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $filter) {
                    ForEach(FilterMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if filtered.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text(NSLocalizedString("还没有历史回顾", comment: "History empty"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(NSLocalizedString("AI 回答和生成的故事会自动保存在这里", comment: "History empty hint"))
                            .font(.footnote)
                            .foregroundStyle(.secondary.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(filtered, id: \.objectID) { conv in
                            NavigationLink {
                                ConversationDetailView(conversation: conv)
                            } label: {
                                ConversationRow(conversation: conv)
                            }
                        }
                        .onDelete(perform: deleteConversations)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(NSLocalizedString("历史回顾", comment: "Conversation history title"))
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "Done")) { dismiss() }
                }
            }
        }
    }

    private func deleteConversations(at offsets: IndexSet) {
        for idx in offsets {
            viewContext.delete(filtered[idx])
        }
        do {
            try viewContext.save()
        } catch {
            Log.error("[ConversationHistory] delete 失败: \(error)", category: .persistence)
        }
    }
}

// MARK: - 列表行

private struct ConversationRow: View {
    let conversation: AIConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: kindIcon)
                    .font(.caption)
                    .foregroundStyle(kindColor)
                Text(kindLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(kindColor)
                if isIncomplete {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(relativeDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(conversation.title ?? "—")
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private var kindIcon: String {
        switch conversation.kindEnum {
        case .askPast: return "bubble.left.and.text.bubble.right"
        case .narrative: return "text.book.closed"
        case .none: return "questionmark.circle"
        }
    }

    private var kindLabel: String {
        switch conversation.kindEnum {
        case .askPast: return NSLocalizedString("回顾", comment: "Kind label: askPast")
        case .narrative: return NSLocalizedString("故事", comment: "Kind label: narrative")
        case .none: return "—"
        }
    }

    private var kindColor: Color {
        switch conversation.kindEnum {
        case .askPast: return .blue
        case .narrative: return .purple
        case .none: return .gray
        }
    }

    private var isIncomplete: Bool {
        if let pl = conversation.askPastPayload {
            return pl.messages.contains { $0.isIncomplete || $0.errorText != nil }
        }
        return conversation.narrativePayload?.isIncomplete ?? false
    }

    private var relativeDate: String {
        guard let date = conversation.createdAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 详情(read-only)

private struct ConversationDetailView: View {
    let conversation: AIConversation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(conversation.title ?? "—")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 8)
                Text(createdAtLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()

                if let pl = conversation.askPastPayload {
                    askPastBody(pl)
                } else if let pl = conversation.narrativePayload {
                    narrativeBody(pl)
                } else {
                    Text(NSLocalizedString("内容已损坏或来自未来版本", comment: "Conversation payload not parseable"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
            .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.chatContentMaxWidth)
        }
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let text = exportPlainText {
                    ShareLink(item: text) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private var createdAtLabel: String {
        guard let date = conversation.createdAt else { return "" }
        return LumoryDateFormatters.fullDateTime.string(from: date)
    }

    @ViewBuilder
    private func askPastBody(_ payload: AIConversation.AskPastPayload) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(payload.messages.enumerated()), id: \.offset) { _, msg in
                askPastMessageRow(msg)
            }
        }
    }

    @ViewBuilder
    private func askPastMessageRow(_ msg: AIConversation.AskPastPayload.Message) -> some View {
        let isUser = msg.role == .user
        let roleLabel = isUser
            ? NSLocalizedString("你", comment: "Role label: user")
            : NSLocalizedString("AI", comment: "Role label: ai")
        VStack(alignment: .leading, spacing: 6) {
            Text(roleLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isUser ? Color.secondary : Color.blue)
            Text(msg.text)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
            if msg.isIncomplete {
                Text(NSLocalizedString("(回答被截断)", comment: "Incomplete answer hint"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let err = msg.errorText, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func narrativeBody(_ payload: AIConversation.NarrativePayload) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "calendar")
                    .font(.caption)
                Text(rangeLabel(start: payload.rangeStart, end: payload.rangeEnd))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if payload.isIncomplete {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(NSLocalizedString("(报告生成时被截断)", comment: "Incomplete narrative hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(payload.body)
                .font(.body)
                .lineSpacing(6)
                .textSelection(.enabled)
        }
    }

    private func rangeLabel(start: Date, end: Date) -> String {
        let f = LumoryDateFormatters.monthDay
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    /// 详情页右上角分享按钮的导出文本(纯文本,不带 markdown)。
    private var exportPlainText: String? {
        if let pl = conversation.askPastPayload {
            return pl.messages.map { msg in
                let prefix = msg.role == .user
                    ? NSLocalizedString("你", comment: "Role label: user")
                    : NSLocalizedString("AI", comment: "Role label: ai")
                return "\(prefix):\n\(msg.text)"
            }.joined(separator: "\n\n")
        }
        if let pl = conversation.narrativePayload {
            return pl.body
        }
        return nil
    }
}
