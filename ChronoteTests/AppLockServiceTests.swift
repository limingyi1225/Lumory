//
//  AppLockServiceTests.swift
//  ChronoteTests
//
//  Tests for `AppLockService`:
//   - **P1-3 fix (2026-05-15 megareview)**: `disable()` 必须 `invalidate()` 在飞的 LAContext,
//     防"用户拨 ON → Face ID 弹窗冒出 → 立刻拨 OFF → 弹窗仍卡屏要等验完"的体验空洞。
//   - 静态 milestone 集合 + enable/disable race 守卫(enableGen)。
//
//  **测试策略**:LAContext 系统真实弹生物认证 UI 不可在 unit test 跑。改测**对外可观察的契约**:
//   - `disable()` 后 `activeAuthContext` 是否 nil-ed
//   - 注入的 LAContext 是否被 `invalidate()` 调用(用 LAContext 子类计数器)
//   - 启用状态切换 + UserDefaults 持久化
//
//  **隔离**:用 `makeForTesting(defaults:)` 起独立 UserDefaults 实例,跨测试不污染。
//

import XCTest
import LocalAuthentication
@testable import Lumory

/// `LAContext` 子类用作 `invalidate()` 行为间谍。`invalidate` 不是 `@objc dynamic`,正常 override
/// 是 Swift 派发,UnitTest 调用 `invalidate()` 会命中子类版本即可。
final class SpyLAContext: LAContext, @unchecked Sendable {
    private(set) var invalidateCallCount = 0
    override func invalidate() {
        invalidateCallCount += 1
        super.invalidate()
    }
}

@MainActor
final class AppLockServiceTests: XCTestCase {

    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        // 每个测试一份独立的 UserDefaults suite,跑完 tearDown 销毁,避免污染真 App Group。
        suiteName = "AppLockServiceTests-\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(testDefaults)
    }

    override func tearDown() async throws {
        testDefaults?.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - P1-3 fix: disable invalidates in-flight LAContext

    /// **P1-3 核心断言**:disable() 必须调被注入 LAContext 的 `invalidate()`,且把 ivar nil 掉。
    func testDisable_invalidatesInFlightLAContext_andClearsIvar() async {
        let service = AppLockService.makeForTesting(defaults: testDefaults)
        let spy = SpyLAContext()
        service.simulateInFlightAuthContextForTesting(spy)

        XCTAssertNotNil(service.activeAuthContextForTesting, "precondition: context should be set")
        XCTAssertEqual(spy.invalidateCallCount, 0, "precondition: invalidate not called yet")

        service.disable()

        XCTAssertEqual(spy.invalidateCallCount, 1, "disable() must invalidate in-flight LAContext (P1-3)")
        XCTAssertNil(service.activeAuthContextForTesting, "disable() must nil out activeAuthContext")
    }

    /// disable 在没有 in-flight context 时不应崩 / 不应抛 / 状态正确。
    func testDisable_withNoInFlightContext_doesNotCrash() {
        let service = AppLockService.makeForTesting(defaults: testDefaults)
        // 不调 simulateInFlightAuthContextForTesting
        XCTAssertNil(service.activeAuthContextForTesting)

        service.disable()

        XCTAssertNil(service.activeAuthContextForTesting)
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.isLocked)
    }

    /// 双重 disable 也安全 — invalidate 只被调一次(因为第二次 ivar 已 nil)。
    /// (2026-05-15 superreview-4 P2)第二次 disable 之间塞一个新 spy 验证它确实被 invalidate。
    /// 原版本只断言 spyA.invalidateCallCount == 1,等价于"nil-safe 不崩",
    /// 不能区分"第二次 disable 真的处理了新 in-flight context"还是"早返 noop"。
    /// 现在多塞 spyB,第二次 disable 必须 invalidate spyB(否则关闭中又触发了新 auth 流的清理失效)。
    func testDisable_twice_invalidatesOnlyOnce() {
        let service = AppLockService.makeForTesting(defaults: testDefaults)
        let spyA = SpyLAContext()
        service.simulateInFlightAuthContextForTesting(spyA)

        service.disable()
        XCTAssertEqual(spyA.invalidateCallCount, 1, "first disable() must invalidate in-flight spy A")
        XCTAssertNil(service.activeAuthContextForTesting, "first disable() must clear active ref")

        // 模拟"disable 之后又因 race / 重入塞进了新的 in-flight context"。第二次 disable
        // 必须 invalidate **spyB**,且不重复 invalidate spyA。
        let spyB = SpyLAContext()
        service.simulateInFlightAuthContextForTesting(spyB)

        service.disable()

        XCTAssertEqual(spyA.invalidateCallCount, 1, "spy A must NOT be re-invalidated by second disable()")
        XCTAssertEqual(spyB.invalidateCallCount, 1, "spy B (set between disables) must be invalidated by second disable()")
        XCTAssertNil(service.activeAuthContextForTesting)
    }

    // MARK: - State persistence

    /// disable() 把 enabled flag 写盘 false,isEnabled / isLocked 翻到 false。
    func testDisable_persistsFlagAndUpdatesState() {
        // Seed: 通过 test seam 标 enabled
        let service = AppLockService.makeForTesting(defaults: testDefaults)
        service.setStateForTesting(enabled: true, locked: true)
        XCTAssertTrue(service.isEnabled)
        XCTAssertTrue(service.isLocked)
        XCTAssertTrue(testDefaults.bool(forKey: "lumory.appLock.enabled"))

        service.disable()

        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.isLocked)
        XCTAssertFalse(testDefaults.bool(forKey: "lumory.appLock.enabled"))
    }

    /// 新实例从 UserDefaults 正确 hydrate enabled 状态。
    func testInit_hydratesEnabledStateFromDefaults() {
        // Write enabled = true
        testDefaults.set(true, forKey: "lumory.appLock.enabled")

        let service = AppLockService.makeForTesting(defaults: testDefaults)

        XCTAssertTrue(service.isEnabled, "init 应该从 defaults 读出 enabled=true")
        XCTAssertTrue(service.isLocked, "enabled=true 时冷启动应该 isLocked=true (需要认证才能进 App)")
    }

    /// 默认 disabled 时新实例不锁。
    func testInit_defaultDisabled_notLocked() {
        let service = AppLockService.makeForTesting(defaults: testDefaults)
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.isLocked)
    }

    // MARK: - lockOnBackground

    /// 启用状态下 lockOnBackground 翻锁。
    func testLockOnBackground_whenEnabled_setsLocked() {
        let service = AppLockService.makeForTesting(defaults: testDefaults)
        service.setStateForTesting(enabled: true, locked: false)

        service.lockOnBackground()

        XCTAssertTrue(service.isLocked)
    }

    /// 未启用时 lockOnBackground 不动状态(回避意外锁屏)。
    func testLockOnBackground_whenDisabled_doesNothing() {
        let service = AppLockService.makeForTesting(defaults: testDefaults)
        // 默认 disabled
        service.lockOnBackground()

        XCTAssertFalse(service.isLocked, "未启用 App Lock 时 lockOnBackground 不该改 isLocked")
    }
}
