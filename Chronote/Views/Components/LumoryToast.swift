import SwiftUI

// MARK: - LumoryToast
//
// 全局 transient toast,**root overlay** 单源。设计原则:
//
// - **一个 service 实例**(`LumoryToastCenter.shared`)driven by `@Observable`,任何 view
//   都能 `LumoryToastCenter.shared.show(...)` 反馈成功 / 信息 / 警告,不需要每个 view 自己挂一份。
// - **挂在 ChronoteApp ZStack 顶层**(在 splash / milestone 之下,在 lock 之上之外),确保
//   sheet 内 / 全屏 cover 内 / Settings 任何深层 view 触发都能看到。
// - **3 秒自动消失** + 重复触发 reset 计时(看门狗 task 模式,跟 InsightsView 旧实现一致)。
// - **底部 capsule + liquidGlassCard**,跟 P0-3 漏勺页贴玻璃统一语言。
//
// 历史背景:之前 toast 实现只在 `InsightsView.swift:233-256` 局部存在。三大高频成功反馈
// (Home 删日记 / Detail 保存 / Home 发送)无视觉确认,toast 反藏在最不重要的"合并主题"流程里 —
// P0-2 把它提到全局并接入 5 处 root events。
//
// 接入清单:
//   * HomeView.deleteEntry — "已删除"
//   * HomeView 发送完成 — "已记录" + .success haptic
//   * DiaryDetailView.saveChanges — "已保存"
//   * ThemeAliasBanner.confirm — "已合并"
//   * ThemeAliasManagementView.confirm — "已合并"

@MainActor
@Observable
final class LumoryToastCenter {
    static let shared = LumoryToastCenter()

    enum Severity: Sendable {
        case success, info, warning

        var iconName: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }

        // 跟 mood-spectrum 系一致的色阶 — 不引入 brand 之外的色板。
        var iconColor: Color {
            switch self {
            case .success: return Color.moodSpectrum(value: 0.85)
            case .info: return Color.moodSpectrum(value: 0.55)
            case .warning: return Color.semanticDestructive
            }
        }
    }

    /// Toast 操作按钮(撤销 / 重试 / 跳转等)。tap 后自动 dismiss + 跑 closure。
    struct Action {
        let label: String
        let perform: @MainActor () -> Void
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let severity: Severity
        // P1-Home-6 撤销按钮 — 点了 toast 自动 dismiss,然后跑 action。closure 引用比较没法 Equatable,
        // 但 Toast 整体走 id 比较,所以 Equatable 仍正确。
        let action: Action?

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// 弹一条 transient toast。重复调用会取消上一条计时,刷新倒计时。
    /// 不直接发 haptic — caller 自己根据语义决定(success/light/medium 各异)。
    /// `duration` 默认 3 秒;有 action 的(如撤销删除)给 4 秒留足反应时间。
    func show(
        _ message: String,
        severity: Severity = .success,
        duration: TimeInterval = 3,
        action: Action? = nil
    ) {
        dismissTask?.cancel()
        current = Toast(message: message, severity: severity, action: action)
        let token = current?.id
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            // Token guard — 如果中间被覆盖过,不要 stomp 新 toast。
            if current?.id == token { current = nil }
        }
    }

    /// 用户点 toast 主动消除(可选用法,防错操作时点掉)。
    func dismissNow() {
        dismissTask?.cancel()
        current = nil
    }

    /// 仅 dismiss "有 action 按钮"的 toast(撤销/重试一类),不动普通 success/info 通知。
    /// **用途**:`EntryDeletionUndoService.commitPendingNow()` 在 4s 窗口失效或后台兜底 commit
    /// 时调用,让"撤销"按钮即刻消失,避免用户看到一个点了不会响应的 dangling 按钮。
    func dismissActionToast() {
        guard current?.action != nil else { return }
        dismissTask?.cancel()
        current = nil
    }

    /// 用户点了 action button — dismiss + 跑 action。区别于 dismissNow:这条路径意味着用户响应了 action。
    func performAction() {
        guard let action = current?.action else {
            dismissNow()
            return
        }
        dismissTask?.cancel()
        current = nil
        action.perform()
    }
}

// MARK: - Overlay view

struct LumoryToastOverlay: View {
    // 直接持 singleton 引用 — `@Observable` 在 body 内 access 自动追踪订阅,不需要 @Bindable wrapper。
    // @Bindable 语义是"提供 sub-binding"(view 写回 store),但本 overlay 完全只读。reviewer Wave-A
    // BUG-P1 指出 @Bindable + @Observable 在 view 重建路径下可能短暂 detach observation,首帧动画偶丢。
    private let center = LumoryToastCenter.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            if let toast = center.current {
                HStack(spacing: 10) {
                    Image(systemName: toast.severity.iconName)
                        .font(.callout)
                        .foregroundStyle(toast.severity.iconColor)
                    Text(toast.message)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    // 有 action 的 toast 在右侧出按钮(撤销 / 重试)。点击 → 跑 action 自动 dismiss。
                    if let action = toast.action {
                        Button(action.label) {
                            center.performAction()
                        }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .liquidGlassCard(cornerRadius: LumoryCornerRadius.chip, interactive: false)
                // §5.14 (2026-05-19) — severity 视觉差异:warning 加左色条 + tint,跟 success/info
                // 的中性灰胶囊一眼区分;之前所有 toast 长得一样,失败/成功靠 icon 区分太弱。
                .overlay(alignment: .leading) {
                    if toast.severity == .warning {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(toast.severity.iconColor)
                            .frame(width: 3)
                            .padding(.vertical, 10)
                            .padding(.leading, 6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: LumoryCornerRadius.chip, style: .continuous))
                .shadow(color: Color.primary.opacity(0.10), radius: 14, y: 4)
                .padding(.horizontal, 24)
                // 距底 36 → 52:之前用户反馈"撤销"按钮跟下方 timeline row 太近,拇指从右下伸过去
                // 容易误穿到 row 上(进 detail / 没撤成)。多 16pt 让 toast 离 row 安全距离更大。
                .padding(.bottom, 52)
                .frame(maxWidth: .infinity)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                // **整 capsule 都是 hit area**(reviewer 之前的设计是"只 action button 才响应",
                // 但用户实际反馈右侧那个文字按钮太小 + 落点偏一点就穿透到下方 row 进 detail)。
                // 现在跟 Apple Photos 删除 toast 一致:有 action 时整 toast tap = 触发 action;
                // 没 action(普通 success/info)tap = dismiss。落点宽容度 ~5x。
                .contentShape(Rectangle())
                .onTapGesture {
                    if toast.action != nil {
                        center.performAction()
                    } else {
                        center.dismissNow()
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(
                    toast.action.map { "\(toast.message). \($0.label)" } ?? toast.message
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(center.current != nil)
        .animation(AnimationConfig.toast, value: center.current)
    }
}

// MARK: - View modifier

extension View {
    /// 给任意视图(尤其是 sheet 内容根)挂上全局 toast overlay。
    ///
    /// **为什么需要在 sheet 内重复挂**:`.sheet` 由系统在 root window 之上呈现,sheet 打开期间
    /// root ZStack 的 overlay 被压在 sheet 之下,看不见。把 overlay 同时挂到 sheet 内容根 → 触发自
    /// sheet 的 toast(比如 ThemeAliasManagement.confirm)能被用户看到。多个 overlay 共享同一
    /// `LumoryToastCenter.shared` 实例,所以是同一条 toast 在两处渲染 — 永远只一个可见。
    func lumoryToastOverlay() -> some View {
        self.overlay {
            LumoryToastOverlay()
                .ignoresSafeArea(.keyboard)
                .allowsHitTesting(true)
        }
    }
}
