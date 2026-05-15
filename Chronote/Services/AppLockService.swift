import Foundation
import LocalAuthentication

/// **App lock(Face ID / Touch ID / 设备密码)**
///
/// 启用后:scenePhase 切到 background → mark locked;切回 active 时显示 LockScreenView,
/// 用户认证通过才进 App。
///
/// **设计 trade-off**:
///   - 进 background 立刻锁(不留 grace 期)。journal 是私密内容,系统级 always-on 才严格,
///     但配 `.lockOnBackground` 已经能挡住"递手机给别人看一眼"场景。
///   - LAPolicy.deviceOwnerAuthentication —— 不强制 Face ID,Face ID 不可用 / 失败几次会自动
///     降级到设备密码。比 `deviceOwnerAuthenticationWithBiometrics` 更鲁棒(eyes shut /
///     口罩 / 借给亲人输 passcode 都能进)。
///   - `isLocked` 初值取 `enabled` —— 启用 lock 的用户冷启动 = 锁定,要先认证。disable 状态
///     永远 unlocked(无视 isLocked ivar 取值,UI 不渲染锁屏)。
///
/// **不做**:
///   - 不存自定义 passphrase(LocalAuthentication 已经盖完整链路)
///   - 不在锁屏阶段强制 always-on data protection(`NSFileProtectionComplete`)—— 那是 product
///     decision,跨整个 SQLite 的事,见 megareview backlog 里"数据 / iCloud schema" 项。
@MainActor
final class AppLockService: ObservableObject {
    static let shared = AppLockService()

    /// "App lock" feature 是否启用。Settings toggle 写。`@AppStorage`-equivalent via UserDefaults 持久化。
    @Published private(set) var isEnabled: Bool

    /// 当前是否锁定(渲染 LockScreenView)。`isEnabled = false` 时这个值无意义。
    @Published private(set) var isLocked: Bool

    private let defaults: UserDefaults
    private let enabledKey = "lumory.appLock.enabled"
    /// Generation token —— enable / disable 用同一个 counter:
    ///   - enable() 前 bump,记 myGen;await 认证完后只有 myGen == enableGen 才提交。
    ///   - disable() 调用 bump 让正在 await 的 enable 不 commit。
    /// 防"反复拨 / 拨 on 后立刻拨 off → 旧 enable 完成覆盖最新 disable"竞态。
    private var enableGen: Int = 0
    /// 当前 in-flight `authenticate` 持有的 LAContext。提到 ivar 是为了 `disable()` 能
    /// `.invalidate()` 关掉系统 Face ID / passcode 弹窗 —— 否则用户拨 ON → 弹窗冒出 → 立刻
    /// 拨 OFF,代码内 isEnabled 已 false 但弹窗仍卡屏要等用户验完才消失,验完"什么也没发生"。
    /// (2026-05-15 megareview P1-3)
    private var activeAuthContext: LAContext?

    private init(defaults: UserDefaults = AppGroup.userDefaults) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: enabledKey)

        // **UI test / screenshot mode 跳过 App Lock**:UITestSampleData 模式下用 in-memory store,
        // simulator 上 LocalAuthentication 也无法通过(没设设备密码),如果之前手测在 simulator 上
        // 启用过 App Lock 把 enabled flag 留在 App Group default 里,下次跑 screenshot test 会被
        // LockScreenView 永久 block,Home 截不到。跟 ReminderService.enable() 同 pattern,test mode
        // 不应继承 production user state。
        #if DEBUG
        if UITestSampleData.isActive {
            self.isEnabled = false
            self.isLocked = false
            return
        }
        #endif

        self.isEnabled = enabled
        // 启用了 → 进程冷启动需要认证;没启用 → 不锁。
        self.isLocked = enabled
    }

    // MARK: - Settings toggle

    /// 启用 app lock。enable 之前先做一次认证 — 否则用户能在没生物验证 / 设备密码的设备上
    /// 启用一个永远进不去的锁。失败:不启用,返回 false。
    /// **Race-safe**:enable 前 bump enableGen,认证完用 myGen 比对当前 gen — 不等则放弃 commit
    /// (用户在认证期间 disable / 重复拨 toggle)。
    func enable() async -> Bool {
        enableGen &+= 1
        let myGen = enableGen
        guard await canEvaluatePolicy() else { return false }
        guard myGen == enableGen else { return false }
        let ok = await authenticate(reason: NSLocalizedString("启用 App 锁前请先验证身份。",
                                                              comment: "Reason for app lock enable"))
        guard ok, myGen == enableGen else { return false }
        defaults.set(true, forKey: enabledKey)
        isEnabled = true
        // 启用瞬间不锁(用户刚验过)。下一次 background → active 才锁。
        isLocked = false
        return true
    }

    func disable() {
        // bump enableGen 把任何 in-flight enable 标 stale,防"用户拨 on → Face ID 弹出 → 用户 cancel
        // 拨 off → enable 内还在 await canEvaluatePolicy,完成后看不到 disable 又写 isEnabled=true"。
        enableGen &+= 1
        // **关闭仍卡屏的系统认证弹窗**(P1-3,2026-05-15 megareview)。如果 enable 流程在 evaluatePolicy
        // 挂起期间 disable 被调,LAContext.invalidate() 让系统认证 UI 立刻消失,evaluatePolicy
        // 用户感知是"拨 OFF 后弹窗也马上没了",而不是"还要验一次脸"。
        activeAuthContext?.invalidate()
        activeAuthContext = nil
        defaults.set(false, forKey: enabledKey)
        isEnabled = false
        isLocked = false
    }

    // MARK: - Lifecycle hooks (ChronoteApp scenePhase 调)

    /// 进 **background OR inactive** → mark locked。
    /// **关键**:必须在 `.inactive` 就锁,不能等 `.background`。iOS 在 `.inactive` 阶段就截屏给 app
    /// switcher 用 — 如果只在 `.background` 锁,用户按 home 键时 multitasking 预览仍能看到日记
    /// timeline,直到 LockScreenView 渲染才覆盖,但那时 snapshot 已经存在系统内。
    /// 在 inactive 立刻 set isLocked = true → SwiftUI 一帧内挂上 LockScreenView → 系统截屏拿到
    /// 锁屏画面而非日记内容。
    /// 没启用 lock 不动状态。
    func lockOnBackground() {
        guard isEnabled else { return }
        isLocked = true
    }

    /// LockScreenView 上"使用 Face ID 解锁"按钮调。成功 isLocked=false 进 App。
    @discardableResult
    func unlock() async -> Bool {
        // **关键 fail-safe**:如果设备的认证策略**已不可用**(用户在 iOS 设置里删了设备密码 /
        // Face ID 失效后没修),`canEvaluatePolicy` 返 false,`evaluatePolicy` 也必然 fail。
        // 这种情况下不能让用户**永久卡在锁屏**——继续锁着也不增加任何安全性(设备本来就没密码),
        // 只伤害合法用户。**自动 disable App Lock 进 App**,事后 Settings 可让用户重新启用。
        if await canEvaluatePolicy() == false {
            Log.warning("[AppLockService] device cannot evaluate policy — auto-disabling App Lock to avoid permanent lockout", category: .general)
            disable()
            return true
        }
        let ok = await authenticate(reason: NSLocalizedString("用 Face ID 解锁 Lumory。",
                                                              comment: "Reason for app lock unlock"))
        if ok {
            isLocked = false
        }
        return ok
    }

    // MARK: - LAContext bridge

    /// 设备能不能跑生物或 passcode 认证。新设备 / 重置后第一次 / 模拟器 → 可能不能。
    func canEvaluatePolicy() async -> Bool {
        let context = LAContext()
        var error: NSError?
        let ok = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        if let error {
            Log.warning("[AppLockService] canEvaluatePolicy=\(ok) error=\(error.localizedDescription)", category: .general)
        }
        return ok
    }

    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        // 把 context 提到 ivar,disable() 能 invalidate 关掉弹窗。(P1-3,2026-05-15 megareview)
        activeAuthContext = context
        let result: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if let error {
                    Log.info("[AppLockService] evaluatePolicy: success=\(success) error=\(error.localizedDescription)", category: .general)
                }
                cont.resume(returning: success)
            }
        }
        // 用完释放,且只在仍是同一个 context 时释放(避免覆盖 disable() 已设的 nil)。
        if activeAuthContext === context {
            activeAuthContext = nil
        }
        return result
    }
}
