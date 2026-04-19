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

    var body: some View {
        ZStack(alignment: .topLeading) {
            backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
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
        streamTask = Task {
            for await chunk in engine.streamNarrative(in: range) {
                if Task.isCancelled { break }
                await MainActor.run {
                    content += chunk
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
        start()
    }

    private func closeTapped() {
        streamTask?.cancel()
        dismiss()
    }
}
