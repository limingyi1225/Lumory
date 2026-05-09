//
//  ReminderLegacyContextualBodyTests.swift
//  ChronoteTests
//
//  回归锁:`ReminderService.loadUseContextualBody` 的 sentinel migration 分支。
//
//  背景:`useContextualBody` 默认从 true 翻成 false 是 privacy-first 决定
//  (AI 生成的 placeholder 含真实主题词,挂到锁屏 body 等于把"妈妈/前任/Abby"明文
//  暴露给肩窥 / 借出去的手机)。但旧版本下激活过 reminder 的老用户已经享受过
//  contextual body,为了不静默吞掉他们的体验,sentinel migration 用
//  `lumory.reminder.enabled`(任意已写值)作为"已激活过"的存在性标志:
//    - useContextualBodyKey 已写过显式值 → 永远尊重显式值
//    - useContextualBodyKey 缺失 + enabledKey 已写过 → legacy 用户 → 一次性写 true 锁住
//    - useContextualBodyKey 缺失 + enabledKey 也缺失 → 真新装机 → false 隐私默认
//
//  ChronoteTests.swift 里的 `ReminderUseContextualBodyDefaultTests` 已覆盖
//  fresh install + 显式 true/false 三个分支,**未覆盖 legacy sentinel 分支**;
//  这里补齐。
//
//  注意:`loadUseContextualBody(from:key:)` 接受任意 useContextualBodyKey 名字
//  做测试隔离,**但 enabledKey 是函数内 hardcode 的字面量 `"lumory.reminder.enabled"`**
//  (ReminderService.swift:295)。所以 legacy 场景必须写到这个真实 key 名;
//  我们用 fresh suite UserDefaults 隔离,不会污染产品 defaults domain。
//

import Testing
import Foundation
@testable import Lumory

struct ReminderLegacyContextualBodyTests {
    /// 测试用的 useContextualBody key — 跟 production key 名隔离,避免误读 / 误写。
    private let contextualKey = "lumory.test.legacy.useContextualBody"

    /// `loadUseContextualBody` 内部 hardcode 的 enabledKey 名(ReminderService.swift:295)。
    /// production key 名,但因为我们用 fresh suite UserDefaults,不污染真实 domain。
    private let enabledKey = "lumory.reminder.enabled"

    private func freshDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    // MARK: - Legacy sentinel 分支(本文件主要覆盖目标)

    /// 老用户激活过 reminder(`enabledKey` 写了 true)+ 没显式碰过 contextual body
    /// → 应返回 true 保留旧体验,且**真的把 true 写进盘**(下次 load 走"显式值"分支幂等)。
    @Test func legacyUser_enabledKeyWritten_contextualKeyMissing_returnsTrue_andPersists() {
        let d = freshDefaults()
        d.set(true, forKey: enabledKey)
        // 前置:contextualKey 真的缺失
        #expect(d.object(forKey: contextualKey) == nil)

        let v = ReminderService.loadUseContextualBody(from: d, key: contextualKey)

        #expect(v == true)
        // sentinel 副作用:把 true 写盘锁住,下次 load 走"显式值"分支(幂等性保证)
        let persisted = d.object(forKey: contextualKey) as? Bool
        #expect(persisted == true)
    }

    /// sentinel 是 **key 存在性**(`object(forKey:) != nil`),不是 `bool(forKey:)` 的 truthy。
    /// 用户主动关过 reminder(`enabledKey` 写了 false)同样算"激活过 feature",
    /// 一样要享受 legacy 保护 → 返回 true。
    /// 这条防止有人重构时手快改成 `if defaults.bool(forKey: enabledKey) { ... }`(语义错)。
    @Test func legacyUser_enabledKeyWrittenFalse_contextualKeyMissing_stillReturnsTrue() {
        let d = freshDefaults()
        d.set(false, forKey: enabledKey)
        #expect(d.object(forKey: contextualKey) == nil)

        let v = ReminderService.loadUseContextualBody(from: d, key: contextualKey)

        #expect(v == true)
        let persisted = d.object(forKey: contextualKey) as? Bool
        #expect(persisted == true)
    }

    // MARK: - 真新装机分支(完整性补齐)

    /// 两个 key 都缺 → 真新装机 → privacy-first 默认 OFF。
    /// **不应**写 sentinel(否则下一次 cold start 看起来像"老用户"被错误升格,
    /// 虽然返回值都是 false 不影响行为,但污染 defaults 不干净)。
    @Test func freshInstall_bothKeysMissing_returnsFalse_andDoesNotPersist() {
        let d = freshDefaults()
        #expect(d.object(forKey: enabledKey) == nil)
        #expect(d.object(forKey: contextualKey) == nil)

        let v = ReminderService.loadUseContextualBody(from: d, key: contextualKey)

        #expect(v == false)
        // 真新装机不应触发 sentinel 写盘
        #expect(d.object(forKey: contextualKey) == nil)
    }

    // MARK: - 显式值分支(防 legacy migration 误覆盖用户主动选择)

    /// 用户已显式 opt-in true → 不管 enabledKey 状态都返 true。
    /// 这条跟 ChronoteTests `explicitTrue_isRespected` 重叠,这里加一层
    /// "enabledKey 也存在" 的组合保证两条分支组合下不互相污染。
    @Test func explicitTrue_withEnabledKeyAlsoSet_returnsTrue() {
        let d = freshDefaults()
        d.set(true, forKey: enabledKey)
        d.set(true, forKey: contextualKey)

        let v = ReminderService.loadUseContextualBody(from: d, key: contextualKey)
        #expect(v == true)
    }

    /// 用户已显式 opt-out false → 不管 enabledKey 状态都返 false。
    /// **关键回归**:防 legacy migration 路径意外把显式 false 当"缺失"处理后误写成 true,
    /// 那就等同于 silently 反转用户选择(隐私 + 信任双 regression)。
    @Test func explicitFalse_withEnabledKeyAlsoSet_returnsFalse() {
        let d = freshDefaults()
        d.set(true, forKey: enabledKey)
        d.set(false, forKey: contextualKey)

        let v = ReminderService.loadUseContextualBody(from: d, key: contextualKey)
        #expect(v == false)
        // 显式值不该被 sentinel 覆盖
        let persisted = d.object(forKey: contextualKey) as? Bool
        #expect(persisted == false)
    }
}
