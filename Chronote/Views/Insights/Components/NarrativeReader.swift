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

    @State private var content: String = ""
    @State private var isStreaming: Bool = false
    @State private var streamTask: Task<Void, Never>?
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
                        if content.isEmpty && isStreaming {
                            ProgressView()
                                .padding(.top, 40)
                        } else {
                            Text(content)
                                .font(.system(size: 17))
                                .lineSpacing(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        if isStreaming && !content.isEmpty {
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
                }
            }
        }
        .onAppear(perform: start)
        .onDisappear {
            streamTask?.cancel()
        }
    }

    // MARK: Incomplete banner

    private var incompleteBanner: some View {
        // content.isEmpty 时说明 stream 压根没产出(离线/401/5xx),banner 显示具体原因(incompleteReason)
        // 替代通用提示,让用户能判断是网络还是配置问题。有部分 content 时仍保留原通用文案 + 重新生成按钮。
        let hasContent = !content.isEmpty
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
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((hasContent ? Color.orange : Color.red).opacity(0.12))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button(action: closeTapped) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.primary.opacity(0.7))
            }
            Spacer()
            if isStreaming {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(NSLocalizedString("AI 正在讲述", comment: "AI is narrating"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if !content.isEmpty {
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
        isStreaming = true
        content = ""
        isIncomplete = false
        incompleteReason = ""
        streamTask = Task {
            // 走结构化事件流 —— 截断时不再把中文 `⚠️ ...` 混进正文,而是让 UI 显示横幅。
            for await event in engine.streamNarrativeEvents(in: range) {
                if Task.isCancelled { break }
                await MainActor.run {
                    switch event {
                    case .chunk(let text):
                        content += text
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
                isStreaming = false
            }
        }
    }

    private func regenerate() {
        streamTask?.cancel()
        streamTask = nil
        isIncomplete = false
        incompleteReason = ""
        start()
    }

    private func closeTapped() {
        streamTask?.cancel()
        dismiss()
    }
}
