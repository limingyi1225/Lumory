//
//  EntryDeletionUndoServiceTests.swift
//  ChronoteTests
//
//  Tests for `EntryDeletionUndoService` — 4 秒撤销窗口 + 同 id 重入 guard + commit-then-undo
//  阻断 + LumoryToastCenter dismissActionToast 不变量。
//
//  **历史**(megareview 标的 OPT-HIGH-7 + P2-3):此 service 直接走 `.shared` 单例,**之前没有**
//  service-level unit test,只在 `EntryWipeOrchestratorTests` 里间接覆盖。本文件锁住几条核心契约。
//
//  **隔离**:
//   - `EntryDeletionUndoService.shared` 走 `resetForTesting()` 把 pending/commitTask 清空(setUp/tearDown)。
//   - `LumoryToastCenter.shared` 走 `dismissNow()` 重置。
//   - PersistenceController(inMemory: true) 起新 store,viewContext 自己持。
//   - **避免真删磁盘 attachment**:测试不种真实文件,snapshot.attachmentImageFileNames 是空数组,
//     Task.detached 的清理一跑就 no-op。
//

import XCTest
import CoreData
@testable import Lumory

@MainActor
final class EntryDeletionUndoServiceTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await EntryDeletionUndoService.shared.resetForTesting()
        LumoryToastCenter.shared.dismissNow()
    }

    override func tearDown() async throws {
        await EntryDeletionUndoService.shared.resetForTesting()
        LumoryToastCenter.shared.dismissNow()
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// 在 inMemory store 插一条 entry + save + 返回 snapshot。
    /// 不写真实 attachment 文件 —— 测试只关心 snapshot/undo lifecycle,不验文件 IO。
    private func makeSnapshot(persistence: PersistenceController, text: String = "test entry") throws -> EntryDeletionSnapshot {
        let ctx = persistence.container.viewContext
        let entry = DiaryEntry(context: ctx)
        entry.id = UUID()
        entry.date = Date()
        entry.text = text
        entry.moodValue = 0.5
        entry.wordCount = Int32(text.count)
        try ctx.save()
        return EntryDeletionSnapshot(entry: entry)
    }

    // MARK: - Register / commit lifecycle

    /// register 一条 → pending 可见 + commitTask 在跑。
    func testRegister_setsPendingAndStartsCommitTask() throws {
        let persistence = PersistenceController(inMemory: true)
        let snapshot = try makeSnapshot(persistence: persistence)

        EntryDeletionUndoService.shared.register(snapshot: snapshot)

        XCTAssertNotNil(EntryDeletionUndoService.shared.pendingSnapshotForTesting, "pending must hold the snapshot")
        XCTAssertEqual(EntryDeletionUndoService.shared.pendingSnapshotForTesting?.id, snapshot.id)
        XCTAssertTrue(EntryDeletionUndoService.shared.commitTaskIsActiveForTesting, "commit task should be in flight")
        XCTAssertTrue(EntryDeletionUndoService.shared.hasPending)
    }

    /// **同 id 重入 guard**(reviewer Wave-A BUG-P0,关键不变量):
    /// 重复 register 同一个 id → 第二次直接 ignore,第一份 snapshot 留下、undo 窗口继续撑。
    /// 老 bug:第二次会立即 commit 第一次,Task.detached 删 attachment → 用户 undo 看到 broken 图。
    func testRegister_sameIdTwice_secondIsIgnored() throws {
        let persistence = PersistenceController(inMemory: true)
        let snapshot = try makeSnapshot(persistence: persistence)

        EntryDeletionUndoService.shared.register(snapshot: snapshot)
        let firstCommitTaskActive = EntryDeletionUndoService.shared.commitTaskIsActiveForTesting

        // 再 register 同一份 snapshot
        EntryDeletionUndoService.shared.register(snapshot: snapshot)

        // pending 仍然是原来那份(没被 commit 然后 replaced)
        XCTAssertNotNil(EntryDeletionUndoService.shared.pendingSnapshotForTesting)
        XCTAssertEqual(EntryDeletionUndoService.shared.pendingSnapshotForTesting?.id, snapshot.id)
        // 第一份 commit task 仍在跑(未被新一次 register cancel + replace)
        XCTAssertEqual(EntryDeletionUndoService.shared.commitTaskIsActiveForTesting, firstCommitTaskActive)
    }

    /// 不同 id register → 第一份立即 commit(pending 被替换 + dismissActionToast 触发)。
    func testRegister_differentId_commitsPriorImmediately() throws {
        let persistence = PersistenceController(inMemory: true)
        let snapshotA = try makeSnapshot(persistence: persistence, text: "A")
        let snapshotB = try makeSnapshot(persistence: persistence, text: "B")

        EntryDeletionUndoService.shared.register(snapshot: snapshotA)
        XCTAssertEqual(EntryDeletionUndoService.shared.pendingSnapshotForTesting?.id, snapshotA.id)

        EntryDeletionUndoService.shared.register(snapshot: snapshotB)

        XCTAssertEqual(EntryDeletionUndoService.shared.pendingSnapshotForTesting?.id, snapshotB.id,
                       "second register should replace pending with snapshot B")
    }

    // MARK: - Undo path

    /// undo 在窗口内 → entry 重建到 viewContext + pending 清空。
    func testUndo_withinWindow_restoresEntryAndClearsPending() throws {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext

        // 先创建 + 删除(模拟正常删除流程的 viewContext 状态)
        let original = DiaryEntry(context: ctx)
        original.id = UUID()
        original.date = Date()
        original.text = "original"
        original.moodValue = 0.7
        try ctx.save()
        let snapshot = EntryDeletionSnapshot(entry: original)
        ctx.delete(original)
        try ctx.save()

        EntryDeletionUndoService.shared.register(snapshot: snapshot)
        let restored = EntryDeletionUndoService.shared.undo(into: ctx)

        let unwrapped = try XCTUnwrap(restored, "undo should return restored entry")
        XCTAssertEqual(unwrapped.id, snapshot.id)
        XCTAssertEqual(unwrapped.text, "original")
        XCTAssertEqual(unwrapped.moodValue, 0.7, accuracy: 0.001)
        XCTAssertNil(EntryDeletionUndoService.shared.pendingSnapshotForTesting,
                     "after undo, pending must be cleared")
        XCTAssertFalse(EntryDeletionUndoService.shared.hasPending)

        // 验证 ctx 里现在确实有那条 entry
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", snapshot.id as NSUUID)
        let found = try ctx.fetch(request)
        XCTAssertEqual(found.count, 1, "restored entry must exist in viewContext")
    }

    /// undo 没东西 → 返 nil。
    func testUndo_withNoPending_returnsNil() throws {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext

        let restored = EntryDeletionUndoService.shared.undo(into: ctx)
        XCTAssertNil(restored)
    }

    // MARK: - commitPendingNow

    /// commitPendingNow → pending 清空 + 不能再 undo。
    func testCommitPendingNow_clearsPendingAndBlocksUndo() throws {
        let persistence = PersistenceController(inMemory: true)
        let snapshot = try makeSnapshot(persistence: persistence)
        EntryDeletionUndoService.shared.register(snapshot: snapshot)
        XCTAssertNotNil(EntryDeletionUndoService.shared.pendingSnapshotForTesting)

        EntryDeletionUndoService.shared.commitPendingNow()

        XCTAssertNil(EntryDeletionUndoService.shared.pendingSnapshotForTesting,
                     "commitPendingNow must clear pending immediately")

        // 此时 undo 应该 noop
        let ctx = persistence.container.viewContext
        let restored = EntryDeletionUndoService.shared.undo(into: ctx)
        XCTAssertNil(restored, "after commit, undo must return nil")
    }

    /// **dangling undo 防护**(reviewer Wave-C BUG-P1):commitPendingNow 必须 dismiss 当前 action toast,
    /// 让"撤销"按钮即刻消失。否则用户回前台看到一个点了不响应的 dangling 按钮。
    func testCommitPendingNow_dismissesActionToast() throws {
        let persistence = PersistenceController(inMemory: true)
        let snapshot = try makeSnapshot(persistence: persistence)

        // Seed:先弹一条带 action 的 toast(模拟"已删除"toast 还在屏)
        var actionFired = false
        LumoryToastCenter.shared.show(
            "已删除",
            severity: .success,
            duration: 60, // 故意拉长,避免被自动 dismiss 干扰
            action: LumoryToastCenter.Action(label: "撤销", perform: { actionFired = true })
        )
        XCTAssertNotNil(LumoryToastCenter.shared.current, "precondition: action toast visible")
        XCTAssertNotNil(LumoryToastCenter.shared.current?.action)

        EntryDeletionUndoService.shared.register(snapshot: snapshot)
        EntryDeletionUndoService.shared.commitPendingNow()

        XCTAssertNil(LumoryToastCenter.shared.current,
                     "commitPendingNow must dismiss the dangling action toast (BUG-P1)")
        XCTAssertFalse(actionFired, "action button must not have been triggered")
    }
}
