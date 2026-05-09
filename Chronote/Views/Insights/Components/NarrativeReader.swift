import SwiftUI

// MARK: - NarrativeReader
//
// 全屏沉浸式阅读器。流式逐字接收 InsightsEngine.streamNarrative() 的输出，
// 背景用 mood 渐变——滚动时轻轻跟随读数。

struct NarrativeReader: View {
    let range: DateInterval
    let title: String
    let engine: InsightsEngine
    let moodHint: Double   // 用于背景渐变初始色

    // 用 SwiftUI 自己的 dismiss 环境，不依赖父 View 传回调。
    // 之前的 `onClose: () -> Void` 捕获了父 view 的 @State binding（`showNarrative = false`）——
    // 如果父 view 在本 reader 还打开时被关掉（比如用户快速推出 Insights 再弹出），
    // 那个闭包就是打到已释放的 State storage，状态不一致。`@Environment(\.dismiss)` 由
    // SwiftUI 自己管 presentation 栈，健壮得多。
    @Environment(\.dismiss) private var dismiss
    /// wave12-3 自动保存历史:report stream 完整结束后存进 AIConversation。
    @Environment(\.managedObjectContext) private var viewContext

    @State private var completedParagraphs: [String] = []
    @State private var trailingParagraph: String = ""
    @State private var isStreaming: Bool = false
    @State private var streamTask: Task<Void, Never>?
    @State private var streamRunID: UUID?
    /// 流被中断但已产出部分内容 —— UI 显示提示条,禁止把半截当完整叙事。
    @State private var isIncomplete: Bool = false
    /// 截断原因 (本地化后的一句话),不一定展示,留给 debug 或未来的 toast。
    @State private var incompleteReason: String = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if isIncomplete {
                    incompleteBanner
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(title)
                            .font(.system(size: 28, weight: .semibold))
                            .padding(.top, 8)
                        if !hasNarrativeContent && isStreaming {
                            ProgressView()
                                .padding(.top, 40)
                        } else {
                            narrativeContent
                        }
                        if isStreaming && hasNarrativeContent {
                            Circle()
                                .fill(Color.primary.opacity(0.5))
                                .frame(width: 8, height: 8)
                                .opacity(0.6)
                                .animation(
                                    Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                                    value: isStreaming
                                )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                    // F7 — iPad / 大窗口阅读宽度限定。正文段落超过 ~720pt 太长会让眼睛跳行不舒服;
                    // chatContentMaxWidth 760pt 是 narrative 长文最舒服的"书本"宽度。iPhone 上自然 < 760pt 不裁剪。
                    .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.chatContentMaxWidth)
                }
            }
        }
        .onAppear(perform: start)
        .onDisappear {
            streamTask?.cancel()
            streamTask = nil
            streamRunID = nil
        }
    }

    // MARK: Incomplete banner

    private var incompleteBanner: some View {
        // 没有正文时说明 stream 压根没产出(离线/401/5xx),banner 显示具体原因(incompleteReason)
        // 替代通用提示,让用户能判断是网络还是配置问题。有部分 content 时仍保留原通用文案 + 重新生成按钮。
        let hasContent = hasNarrativeContent
        let headline: String = hasContent
            ? NSLocalizedString("stream.incomplete.banner", comment: "Stream truncated hint")
            : (incompleteReason.isEmpty
                ? NSLocalizedString("stream.incomplete.banner", comment: "Stream truncated hint")
                : incompleteReason)
        return HStack(spacing: 10) {
            Image(systemName: hasContent ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .foregroundStyle(hasContent ? .orange : .red)
                .font(.caption)
            Text(headline)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
            Button {
                regenerate()
            } label: {
                Text(NSLocalizedString("stream.incomplete.regenerate", comment: "Regenerate"))
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // P1-Ins-17 玻璃化 — 替 RoundedRectangle.fill(.opacity 0.12) 实色块,跟其他 inline banner
        // 视觉对齐。tint 保留 orange/red 表达 severity。
        .liquidGlassCard(
            cornerRadius: LumoryCornerRadius.inline,
            tint: hasContent ? Color.orange : Color.red,
            tintStrength: 0.14
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            // P1-Ins-17 关闭按钮玻璃化 — 替平面 SF Symbol,glassCircle interactive 给清晰按下反馈。
            Button(action: closeTapped) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .liquidGlassCircle(interactive: true)
            }
            .buttonStyle(PressableScaleButtonStyle())
            Spacer()
            if isStreaming {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(NSLocalizedString("AI 正在讲述", comment: "AI is narrating"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if hasNarrativeContent {
                Button(action: regenerate) {
                    Label(NSLocalizedString("重新生成", comment: "Regenerate"), systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color.moodSpectrum(value: moodHint).opacity(0.18),
                Color.moodSpectrum(value: max(0, min(1, moodHint + 0.2))).opacity(0.06),
                Color(.systemBackground)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: Streaming lifecycle

    private func start() {
        guard streamTask == nil else { return }
        let runID = UUID()
        streamRunID = runID
        isStreaming = true
        completedParagraphs = []
        trailingParagraph = ""
        isIncomplete = false
        incompleteReason = ""
        streamTask = Task {
            // 走结构化事件流 —— 截断时不再把中文 `⚠️ ...` 混进正文,而是让 UI 显示横幅。
            for await event in engine.streamNarrativeEvents(in: range) {
                if Task.isCancelled { break }
                await MainActor.run {
                    guard streamRunID == runID else { return }
                    switch event {
                    case .chunk(let text):
                        appendNarrativeChunk(text)
                    case .truncated(let reason):
                        isIncomplete = true
                        incompleteReason = reason
                    case .failed(let error):
                        isIncomplete = true
                        incompleteReason = error.localizedDescription
                    case .done:
                        break
                    }
                }
            }
            await MainActor.run {
                guard streamRunID == runID else { return }
                isStreaming = false
                streamTask = nil
                streamRunID = nil
                // **wave12-3 自动保存历史**(codex review:用 generation guard 防 stale write,
                // 这里 streamRunID 已 guard 过)。每次完整结束保存一条 AIConversation 记录。
                // 跳过条件:零内容(用户 dismiss 太快 / streamReport 立即 .done 空报告)。
                // 保存条件:有 completedParagraphs / trailingParagraph,即便 isIncomplete 也存
                // (用户希望"半截但有用"也能回看)。
                self.persistNarrativeIfNeeded()
            }
        }
    }

    /// 把刚结束的 narrative 报告存进 CoreData。fire-and-forget,失败仅 Log。
    private func persistNarrativeIfNeeded() {
        let body: String = {
            let paragraphs = completedParagraphs + (trailingParagraph.isEmpty ? [] : [trailingParagraph])
            return paragraphs.joined(separator: "\n\n")
        }()
        guard !body.isEmpty else { return }

        let payload = AIConversation.NarrativePayload(
            rangeStart: range.start,
            rangeEnd: range.end,
            body: body,
            isIncomplete: isIncomplete,
            truncatedReason: incompleteReason.isEmpty ? nil : incompleteReason
        )
        do {
            _ = try AIConversation.insertNarrative(
                in: viewContext,
                title: title,
                payload: payload,
                citedEntryIds: []
            )
            try viewContext.save()
        } catch {
            Log.error("[NarrativeReader] 持久化 narrative 历史失败: \(error)", category: .persistence)
        }
    }

    private func regenerate() {
        streamTask?.cancel()
        streamTask = nil
        streamRunID = nil
        isIncomplete = false
        incompleteReason = ""
        start()
    }

    private func closeTapped() {
        streamTask?.cancel()
        streamTask = nil
        streamRunID = nil
        dismiss()
    }

    private var hasNarrativeContent: Bool {
        !completedParagraphs.isEmpty || !trailingParagraph.isEmpty
    }

    private var narrativeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(completedParagraphs.enumerated()), id: \.offset) { _, paragraph in
                narrativeParagraph(paragraph)
            }
            if !trailingParagraph.isEmpty {
                narrativeParagraph(trailingParagraph)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func narrativeParagraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 17))
            .lineSpacing(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func appendNarrativeChunk(_ text: String) {
        let merged = trailingParagraph + text
        let parts = merged.components(separatedBy: "\n\n")
        guard parts.count > 1 else {
            trailingParagraph = merged
            return
        }
        completedParagraphs.append(contentsOf: parts.dropLast().filter { !$0.isEmpty })
        trailingParagraph = parts.last ?? ""
    }
}
