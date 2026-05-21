import SwiftUI
import CoreData

// MARK: - ConversationHistoryView
//
// **历史回顾入口**。`AIConversation` entity 装两类 AI 输出历史:AskPast 一次次
// Q+A pair / NarrativeSummaryCard 一份份生成的报告。
//
// 入口拆开:
// - `AskPastView` 的 history 按钮 → `filterKind: .askPast` 只看提问记录
// - `NarrativeDetailSheet` ellipsis Menu → `filterKind: .narrative` 只看 AI 回顾
//
// **设计(2026-05-19 v2 redesign)**:
// 列表换玻璃卡片 row,跟 ThemeAliasManagementView / Insights chip 同语言。
// 每张卡:大标题(问题 / 时间窗)+ 副标题(几条 cite / 篇数)+ 相对时间右上角。
// 删走 leading-edge swipe。空态 + 详情页都用 LumoryFonts + token spacing。

struct ConversationHistoryView: View {
    /// §2.3 (2026-05-19) — 历史拆两条:`.narrative` 只显 AI 回顾(从 NarrativeDetailSheet 入),
    /// `.askPast` 只显用户提问(从 AskPastView 入)。`nil` 沿用 legacy mixed list 行为。
    let filterKind: AIConversation.Kind?

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @FetchRequest private var conversations: FetchedResults<AIConversation>

    @State private var pendingDeletion: AIConversation?
    @State private var selectedConversation: AIConversation?

    private var allRecords: [AIConversation] {
        Array(conversations)
    }

    /// nav title 根据 filter 切换。
    private var localizedTitle: String {
        switch filterKind {
        case .narrative: return NSLocalizedString("回顾历史", comment: "Narrative history title")
        case .askPast: return NSLocalizedString("提问历史", comment: "Ask Past history title")
        case .none: return NSLocalizedString("历史回顾", comment: "Conversation history title (mixed)")
        }
    }

    private var localizedEmptyTitle: String {
        switch filterKind {
        case .narrative: return NSLocalizedString("还没有回顾", comment: "Empty state: no narrative history")
        case .askPast: return NSLocalizedString("还没有提问记录", comment: "Empty state: no Ask Past history")
        case .none: return NSLocalizedString("还没有历史回顾", comment: "History empty (mixed)")
        }
    }

    private var localizedEmptySubtitle: String {
        switch filterKind {
        case .narrative:
            return NSLocalizedString(
                "在 Insights 里生成一份 AI 回顾,这里会留下时间轴。",
                comment: "Empty subtitle for narrative history"
            )
        case .askPast:
            return NSLocalizedString(
                "问几个关于过去的问题,记录会出现在这里。",
                comment: "Empty subtitle for askPast history"
            )
        case .none:
            return ""
        }
    }

    init(filterKind: AIConversation.Kind? = nil) {
        self.filterKind = filterKind
        let request: NSFetchRequest<AIConversation> = AIConversation.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \AIConversation.createdAt, ascending: false)]
        request.fetchBatchSize = 50
        request.fetchLimit = 300
        if let filterKind {
            request.predicate = NSPredicate(format: "kind == %@", filterKind.rawValue)
        }
        _conversations = FetchRequest(fetchRequest: request)
    }

    var body: some View {
        // (2026-05-19 superreview P1)confirmationDialog 挂到 NavigationStack **外层**:
        // 原本在 Group { if/else } 内,Group identity 跟着条件渲染抖,删完最后一条 list ↔ empty
        // 切换时 dialog 会被一起拆掉。挪到 NavigationStack 之上,锚到永远稳定的 view 根。
        NavigationStack {
            Group {
                if allRecords.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle(localizedTitle)
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("完成", comment: "Done")) { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .confirmationDialog(
            NSLocalizedString("删除这条记录?", comment: "Delete conversation confirm title"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                // (2026-05-19 superreview)snapshot target 先,再清 pendingDeletion —
                // 顺序保险:SwiftUI 在 dialog dismiss 时也会调 setter set false,避免 race。
                let snapshot = pendingDeletion
                pendingDeletion = nil
                if let target = snapshot {
                    #if canImport(UIKit)
                    HapticManager.shared.notification(.warning)
                    #endif
                    delete(target)
                }
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text(NSLocalizedString("此操作不可撤销。日记本身不受影响。",
                                   comment: "Delete conversation confirm body"))
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: emptyIcon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 8) {
                Text(localizedEmptyTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                if !localizedEmptySubtitle.isEmpty {
                    Text(localizedEmptySubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyIcon: String {
        switch filterKind {
        case .narrative: return "text.book.closed"
        case .askPast: return "bubble.left.and.text.bubble.right"
        case .none: return "clock.arrow.circlepath"
        }
    }

    // MARK: - List

    /// (2026-05-19 superreview P1)用 List 而非 ScrollView+LazyVStack — List 才支持原生
    /// `.swipeActions(edge: .trailing)` 滑动删除(iOS 用户主要的删除习惯)。Row 卡片视觉走
    /// `.listRowBackground(.clear) + .listRowSeparator(.hidden) + .listRowInsets(16/16)`,
    /// 让 liquidGlassCard 自己撑形,跟 ThemeAliasManagementView pendingCard 同 idiom。
    /// (codex 终审 2026-05-19) 老实现用 `ZStack { 0-opacity NavigationLink(EmptyView) + visible row }`
    /// 隐 disclosure chevron。Codex 反馈:NavigationLink label 是 EmptyView 时 hit target 可能
    /// 塌缩到 0×0,tap 整 row 不能可靠走 nav。改成把 row 放进 NavigationLink label —— 接受默认
    /// 出现的小 chevron(iOS 标准 nav 视觉),换取 hit target 一定是整行的可靠性。
    private var list: some View {
        List {
            ForEach(allRecords, id: \.objectID) { conv in
                Button {
                    #if canImport(UIKit)
                    HapticManager.shared.impact(.light)
                    #endif
                    selectedConversation = conv
                } label: {
                    ConversationGlassRow(conversation: conv)
                }
                .buttonStyle(PressableScaleButtonStyle())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDeletion = conv
                    } label: {
                        Label(
                            NSLocalizedString("删除", comment: "Delete"),
                            systemImage: "trash"
                        )
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        pendingDeletion = conv
                    } label: {
                        Label(
                            NSLocalizedString("删除", comment: "Delete"),
                            systemImage: "trash"
                        )
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.chatContentMaxWidth)
        .navigationDestination(item: $selectedConversation) { conv in
            ConversationDetailView(conversation: conv)
        }
    }

    private func delete(_ conversation: AIConversation) {
        #if canImport(UIKit)
        HapticManager.shared.impact(.medium)
        #endif
        viewContext.delete(conversation)
        do {
            try viewContext.save()
        } catch {
            Log.error("[ConversationHistory] delete 失败: \(error)", category: .persistence)
            viewContext.rollback()
        }
    }
}

// MARK: - Glass card row

private struct ConversationGlassRow: View {
    let conversation: AIConversation
    @AppStorage("appLanguage", store: AppGroup.userDefaults) private var appLanguage: String = {
        Locale.current.identifier.hasPrefix("zh") ? "zh-Hans" : "en"
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // (2026-05-19 user feedback round 3)去掉 kind 图标(book / bubble) —
            // 历史页 nav title 已经按 filter 区分(回顾历史 vs 提问历史),row 前再挂个图标
            // 是重复信号。标题直接打头,视觉更干净。
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(conversation.title ?? "—")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
            }
            HStack(spacing: 6) {
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isIncomplete {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                Text(relativeDate)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: LumoryCornerRadius.card, style: .continuous))
        .liquidGlassCard(cornerRadius: LumoryCornerRadius.card, interactive: true)
    }

    // (C-04 / H-7 superreview 2026-05-19) 删 dead `kindIcon` / `kindColor` —— diff 已经
    // 删了 row 顶部的 kind icon + 颜色标签(因为 nav title 已经按 filter 区分了 askPast vs
    // narrative,row 内 icon 是冗余信息),但这两个 computed property 当时漏删,grep 全文
    // 无 read 点。

    /// 副标题:askPast 显引用篇数(若有);narrative 显时间窗 + 篇数。
    private var subtitle: String? {
        switch conversation.kindEnum {
        case .askPast:
            if let pl = conversation.askPastPayload {
                // (C-05 superreview 2026-05-19) `Set` 去重 —— 单 turn 没影响,但多 turn askPast
                // 落地后同一篇日记被多条消息引用会 inflate "引用 N 篇" 的计数。语义是"引用了几篇
                // 不同的日记",必须 dedupe。
                let citedCount = Set(pl.messages.flatMap { $0.citedEntryIds }).count
                if citedCount > 0 {
                    return String(
                        format: NSLocalizedString("引用 %d 篇", comment: "askPast cited entries count"),
                        citedCount
                    )
                }
            }
            return nil
        case .narrative:
            guard let pl = conversation.narrativePayload else { return nil }
            var s: String
            if pl.rangeKind == TimeRange.all.rawValue {
                s = NSLocalizedString("全部时间", comment: "Time range all")
            } else {
                let f = LumoryDateFormatters.monthDay(language: appLanguage)
                s = "\(f.string(from: pl.rangeStart)) – \(f.string(from: pl.rangeEnd))"
            }
            if let count = pl.entryCount, count > 0 {
                s += " · "
                s += String(format: NSLocalizedString("%d 篇", comment: "Entry count short"), count)
            }
            return s
        case .none: return nil
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

// MARK: - Detail (read-only, iOS 26 typography)

private struct ConversationDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage", store: AppGroup.userDefaults) private var appLanguage: String = {
        Locale.current.identifier.hasPrefix("zh") ? "zh-Hans" : "en"
    }()
    let conversation: AIConversation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                    .opacity(0.4)
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
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 48)
            .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.chatContentMaxWidth)
        }
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    #if canImport(UIKit)
                    HapticManager.shared.impact(.light)
                    #endif
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let text = exportPlainText {
                    ShareLink(item: text) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(NSLocalizedString("分享", comment: "Share"))
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(conversation.title ?? "—")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.caption2)
                Text(createdAtLabel)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var createdAtLabel: String {
        guard let date = conversation.createdAt else { return "" }
        return LumoryDateFormatters.fullDateTime(language: appLanguage).string(from: date)
    }

    @ViewBuilder
    private func askPastBody(_ payload: AIConversation.AskPastPayload) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(payload.messages.enumerated()), id: \.offset) { _, msg in
                askPastMessageRow(msg)
            }
        }
    }

    @ViewBuilder
    private func askPastMessageRow(_ msg: AIConversation.AskPastPayload.Message) -> some View {
        let isUser = msg.role == .user
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: isUser ? "person.fill" : "sparkles")
                .font(.caption.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isUser ? Color.secondary : Color.accentColor)
                .accessibilityLabel(isUser
                                    ? NSLocalizedString("你", comment: "Role label: user")
                                    : NSLocalizedString("AI", comment: "Role label: ai"))
            // (C-19 superreview 2026-05-19) 用户消息走 plain Text,AI 消息保留 MarkdownText。
            // 老实现两边都用 MarkdownText,用户当时输入 `*foo*` 在历史详情会被渲染成加粗,
            // 跟用户提问那一刻看到的不一致(输入框是 plain Text)。
            if isUser {
                Text(msg.text)
                    .font(.body)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                MarkdownText(
                    markdown: msg.text,
                    inlineFont: .body,
                    lineSpacing: 5,
                    preserveLineBreaks: true
                )
                .textSelection(.enabled)
            }
            if msg.isIncomplete {
                Text(NSLocalizedString("(回答被截断)", comment: "Incomplete answer hint"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let err = msg.errorText, !err.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: LumoryCornerRadius.inline, style: .continuous)
                        .fill(Color.red.opacity(0.08))
                )
            }
        }
    }

    @ViewBuilder
    private func narrativeBody(_ payload: AIConversation.NarrativePayload) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.caption2)
                Text(rangeLabel(for: payload))
                    .font(.caption)
                if let count = payload.entryCount, count > 0 {
                    Text("·")
                        .font(.caption)
                    Text(String(format: NSLocalizedString("%d 篇日记", comment: "Narrative provenance entry count"), count))
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)

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

            if let headline = payload.headline, !headline.isEmpty {
                Text(headline)
                    .font(LumoryFonts.narrativeBodyTitle)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineSpacing(6)
                    .padding(.top, 4)
                    .textSelection(.enabled)
                Divider()
                    .opacity(0.4)
            }

            MarkdownText(
                markdown: payload.body,
                inlineFont: .body,
                lineSpacing: 6,
                preserveLineBreaks: true
            )
            .textSelection(.enabled)
        }
    }

    private func rangeLabel(for payload: AIConversation.NarrativePayload) -> String {
        if payload.rangeKind == TimeRange.all.rawValue {
            return NSLocalizedString("全部时间", comment: "Time range all")
        }
        let f = LumoryDateFormatters.monthDay(language: appLanguage)
        return "\(f.string(from: payload.rangeStart)) – \(f.string(from: payload.rangeEnd))"
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
            // (C-26 superreview 2026-05-19) narrative 渲染时分 headline + body 两块,但旧
            // exportPlainText 只导 body —— 分享出去的内容跟详情页看到的对不上(标题"诗意大字"
            // 那一句没了)。prepend headline 让分享文本跟视觉一致。
            if let headline = pl.headline, !headline.isEmpty {
                return "\(headline)\n\n\(pl.body)"
            }
            return pl.body
        }
        return nil
    }
}
