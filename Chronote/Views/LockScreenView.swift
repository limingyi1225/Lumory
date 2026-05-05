import SwiftUI

/// **App lock 锁屏覆盖**
///
/// `AppLockService.isEnabled && isLocked` 时 ChronoteApp 在主内容上盖一层 fullScreenCover(or
/// ZStack 顶层),用户必须 Face ID / 设备密码通过才能进。
///
/// 设计:中央 lock icon + "Lumory" + "解锁" 按钮 + 进度文字。背景纯黑 / dark gradient,
/// 不显示任何日记内容(被锁的时候怎么能 leak 内容)。
struct LockScreenView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var lockService = AppLockService.shared
    @State private var isAuthenticating = false
    @State private var lastFailureMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // 顶部到底的微弱 gradient,纯黑显得太"死",这层让有点 depth。
            LinearGradient(
                colors: [Color.black, Color.black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 8) {
                    Text("Lumory")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(NSLocalizedString("已锁定 — 请验证身份后继续",
                                           comment: "App lock screen subtitle"))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Button {
                    Task { await tryUnlock() }
                } label: {
                    HStack(spacing: 8) {
                        if isAuthenticating {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        } else {
                            Image(systemName: "faceid")
                        }
                        Text(NSLocalizedString("解锁", comment: "App lock unlock button"))
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isAuthenticating)

                if let lastFailureMessage {
                    Text(lastFailureMessage)
                        .font(.footnote)
                        .foregroundStyle(.red.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()
            }
        }
        // 冷启动时自动尝试一次认证 — 用户预期的是"打开 App 直接弹 Face ID",不是先看到锁屏再点解锁。
        // 但 App 为了保护 app switcher snapshot 会在 `.inactive` 先挂锁屏；那一帧不能触发 LA。
        .task(id: scenePhase) {
            guard scenePhase == .active, lockService.isLocked else { return }
            await tryUnlock()
        }
    }

    private func tryUnlock() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        lastFailureMessage = nil
        let ok = await lockService.unlock()
        isAuthenticating = false
        if !ok {
            lastFailureMessage = NSLocalizedString("解锁失败,请重试。",
                                                    comment: "App lock unlock failure")
        }
    }
}
