//
//  HomeView+Entry.swift
//  Lumory
//
//  HomeView 的 entry 级生命周期:删除单条日记(走 4 秒撤销 toast)+ 数据库重建
//  (`databaseRecreated` 通知接住,清本地 state)。
//
//  入口:
//   - `deleteEntry(_:)` — `HomeTimelineList` 的 onDelete 回调
//   - `handleDatabaseRecreation()` — `.onReceive(.databaseRecreated)` 触发,清音频 /
//     输入 / 转写 task / refreshAllObjects
//

import SwiftUI
import CoreData

extension HomeView {

    func deleteEntry(_ entry: DiaryEntry) {
        // Check if the entry to be deleted is the currently selected one for navigation
        if selectedEntry?.objectID == entry.objectID {
            selectedEntry = nil // Prevent navigation to a deleted item
        }
        let entryObjectID = entry.objectID

        // 先停止可能的音频播放，如果该条目正在播放
        if self.audioPlaybackController.currentPlayingFileName == entry.audioFileName {
            self.audioPlaybackController.stopPlayback(clearCurrentFile: true)
        }

        // P1-Home-6 抓快照 — 必须在 viewContext.delete 之前(@NSManaged 访问 deleted entry 会 crash)。
        // attachment 文件**不**在这里删,延迟到 commitPendingNow 跑(让撤销窗口里 restore 时文件还在)。
        let snapshot = EntryDeletionSnapshot(entry: entry)

        // Perform deletion within a withAnimation block for smoother UI updates.
        // **register / show 故意挪出 withAnimation**(reviewer P1):toast `show()` mutate `@Observable`
        // 字段时如果在 withAnimation 里,会跟 LumoryToastOverlay 自带的 `AnimationConfig.toast` 叠成
        // 两层动画,节奏跑偏。其他 3 个删除 callsite(DiaryDetail / ThemeFiltered / PointDetail)都
        // 在 withAnimation 之外做,这里改成同一 idiom 保持一致。
        var didSucceed = false
        withAnimation {
            viewContext.delete(entry)

            do {
                try viewContext.save()
                didSucceed = true
            } catch {
                // Log the error appropriately
                Log.error("[HomeView] 删除日记失败: \(error.localizedDescription)", category: .ui)
                viewContext.rollback()
            }
        }

        guard didSucceed else { return }
        removeDeletedEntryFromSearchResults(entryObjectID)
        HapticManager.shared.impact(.medium)
        // 单删派生缓存清理统一走 EntryWipeOrchestrator(Reminder + Prompt + Insights + alias 孤儿清理)。
        // 注意:这层是聚合刷新,不删 attachment 文件 — attachment 由 EntryDeletionUndoService 4s 后清。
        EntryWipeOrchestrator.performSingleDeleteCleanup()

        // P1-Home-6 注册到 undo service + 弹带"撤销"按钮的 toast。4 秒内点撤销 → entry 复活。
        let viewContextRef = viewContext
        EntryDeletionUndoService.shared.register(snapshot: snapshot)
        LumoryToastCenter.shared.show(
            NSLocalizedString("已删除", comment: "Toast after entry deletion"),
            severity: .success,
            duration: EntryDeletionUndoService.undoWindow,
            action: LumoryToastCenter.Action(
                label: NSLocalizedString("撤销", comment: "Undo delete action")
            ) {
                if EntryDeletionUndoService.shared.undo(into: viewContextRef) != nil {
                    #if canImport(UIKit)
                    HapticManager.shared.notification(.success)
                    #endif
                }
            }
        )
    }

    func handleDatabaseRecreation() {
        // Clear any local state that might reference deleted objects
        selectedEntry = nil

        // Stop any ongoing audio playback
        audioPlaybackController.stopPlayback(clearCurrentFile: true)

        // Clear input state
        inputVM.inputText = ""
        recordingVM.currentAudioFileName = nil
        recordingVM.audioRecordings.removeAll()
        photoVM.selectedImageItems.removeAll()
        photoVM.selectedPhotos.removeAll()
        inputVM.moodValue = 0.5

        // Cancel any ongoing tasks
        transcriptionGeneration &+= 1
        recordingVM.transcriptionTask?.cancel()
        recordingVM.transcriptionTask = nil
        recordingVM.isTranscribing = false

        // Force Core Data to refresh
        viewContext.refreshAllObjects()

        // Haptic feedback to indicate refresh
        #if canImport(UIKit)
        HapticManager.shared.click()
        #endif

        Log.info("[HomeView] Database recreation handled - state cleared and context refreshed", category: .ui)
    }
}
