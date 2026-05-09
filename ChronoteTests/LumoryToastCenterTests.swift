//
//  LumoryToastCenterTests.swift
//  ChronoteTests
//
//  P1 回归测:`LumoryToastCenter` 状态机 — 撤销删除功能(EntryDeletionUndoService)的命脉。
//  这台 singleton 一旦坏:
//    - show/dismiss/dismissActionToast/performAction 任何分支挂掉
//    - token guard 失效 → 旧 timer stomp 新 toast
//    - action 闭包没跑 / current 没清
//  → 用户撤销操作直接失效(toast 看不到 / 撤销按钮点了不响应 / 残留 dangling 按钮)。
//  测试用 short duration + 宽松 sleep 容差(80ms 而非 50ms 卡边界),不写 nanoseconds 精度。
//

import Testing
import Foundation
@testable import Lumory

@MainActor
struct LumoryToastCenterTests {
    /// 每个测试前 reset singleton 状态,避免上一个测试残留 toast 污染。
    private func reset() {
        LumoryToastCenter.shared.dismissNow()
    }

    // MARK: - show

    @Test func show_setsCurrent_andSeverity() async throws {
        reset()
        let center = LumoryToastCenter.shared
        center.show("hi", severity: .success, duration: 10)
        #expect(center.current?.message == "hi")
        #expect(center.current?.severity == .success)
        #expect(center.current?.action == nil)
        reset()
    }

    @Test func show_withAction_storesActionAndExposes() async throws {
        reset()
        let center = LumoryToastCenter.shared
        let action = LumoryToastCenter.Action(label: "撤销") {}
        center.show("已删除", severity: .success, duration: 10, action: action)
        #expect(center.current?.action?.label == "撤销")
        #expect(center.current?.message == "已删除")
        reset()
    }

    // MARK: - duration auto-dismiss

    @Test func show_durationDismissesAfterSleep() async throws {
        reset()
        let center = LumoryToastCenter.shared
        center.show("flash", severity: .info, duration: 0.05)
        #expect(center.current != nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(center.current == nil)
        reset()
    }

    // MARK: - dismissNow

    @Test func dismissNow_clearsCurrentImmediately() async throws {
        reset()
        let center = LumoryToastCenter.shared
        center.show("long", severity: .success, duration: 100)
        #expect(center.current != nil)
        center.dismissNow()
        #expect(center.current == nil)
        reset()
    }

    // MARK: - dismissActionToast

    @Test func dismissActionToast_onlyClearsActionToasts_keepsPlainSuccessVisible() async throws {
        reset()
        let center = LumoryToastCenter.shared
        // 普通 toast(无 action)— dismissActionToast 不应触碰它
        center.show("已保存", severity: .success, duration: 100)
        #expect(center.current != nil)
        #expect(center.current?.action == nil)
        center.dismissActionToast()
        // 普通 toast 仍存在
        #expect(center.current != nil)
        #expect(center.current?.message == "已保存")
        reset()
    }

    @Test func dismissActionToast_clearsActionToast() async throws {
        reset()
        let center = LumoryToastCenter.shared
        let action = LumoryToastCenter.Action(label: "撤销") {}
        center.show("已删除", severity: .success, duration: 100, action: action)
        #expect(center.current?.action != nil)
        center.dismissActionToast()
        #expect(center.current == nil)
        reset()
    }

    // MARK: - token / generation guard

    @Test func repeatedShow_overwritesPreviousAndCancelsOldTimer() async throws {
        reset()
        let center = LumoryToastCenter.shared
        // 第一个 toast,duration 0.1s — 如果旧 timer 没被取消,会在 100ms 处把第二个 toast stomp 掉
        center.show("first", severity: .info, duration: 0.1)
        let firstID = center.current?.id
        // 立即覆盖第二个,duration 1s
        center.show("second", severity: .success, duration: 1.0)
        let secondID = center.current?.id
        #expect(firstID != secondID)
        #expect(center.current?.message == "second")

        // 等到第一个 timer 早就该 fire 但第二个还远没到的时刻
        try await Task.sleep(for: .milliseconds(250))
        // 旧 timer 必须没 stomp 新 toast(token guard 起效)
        #expect(center.current?.id == secondID)
        #expect(center.current?.message == "second")
        reset()
    }

    // MARK: - performAction

    @Test func performAction_runsClosureAndDismisses() async throws {
        reset()
        let center = LumoryToastCenter.shared
        // 用 actor-isolated mutable counter via box(@MainActor 类内是安全的简单 wrapper)
        final class Counter { var value = 0 }
        let counter = Counter()
        let action = LumoryToastCenter.Action(label: "撤销") {
            counter.value += 1
        }
        center.show("已删除", severity: .success, duration: 100, action: action)
        #expect(counter.value == 0)
        #expect(center.current != nil)

        center.performAction()

        #expect(counter.value == 1)
        #expect(center.current == nil)
        reset()
    }
}
