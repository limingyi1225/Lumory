import CoreData
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum SettingsEntryDeletionService {
    static func deleteAll(viewContext: NSManagedObjectContext) async -> Bool {
        // **P1 fix (2026-05-13 superreview round 2)**:原顺序"delete + save → 之后 await
        // performBulkWipeCleanup 内才 cancelPending",中间窗口 NarrativePrecompute 在飞 task
        // 可能正在写 fresh narrative,delete + save 完成后才被 bulk wipe 后续 clear 绕弯抓。
        // **先 cancel + bump generation,再 delete + save** —— 让 bg writer 在 actor 守卫前
        // 停掉。performBulkWipeCleanup 内也仍调一次 cancel(幂等,无害)。
        await NarrativePrecomputeService.shared.cancelPendingAndBumpGeneration()
        // wave18 — 用户主动触发的生成也归 coordinator,跟 precompute 一起 cancel + drain,
        // 否则在飞 task 会在 delete + save 后写回 narrative(performBulkWipeCleanup 内也再调
        // 一次,幂等无害)。
        await NarrativeGenerationCoordinator.shared.cancelAll()

        // **P1 fix (2026-05-15 megareview)**:不再信任 caller 传 snapshot,**在 cancel & save 边界
        // 之间重新 fetch 一次**抓"alert 弹窗到用户确认中间 CloudKit 同步进新 entry"的 race。
        // 原实现:caller `SettingsView.deleteAllEntries` 在 alert tap 时刻 snapshot `Array(entries)`,
        // 之间隔了 alert 等用户秒级时间,新 entry 同步进来后没在快照里 → 没被删 → UI 说"全删了"
        // 但实际幸存。Settings 全删是确定的 destructive 操作,re-fetch 拿到当前所有再删才符合直觉。
        let allEntriesRequest = NSFetchRequest<DiaryEntry>(entityName: "DiaryEntry")
        // (2026-05-15 superreview P2)`@MainActor` 路径 sync fetch 全表 + 之后 fault 每条
        // attachmentSnapshot,>5k entry 用户 tap 确认时 100-500ms 卡顿。batchSize 把 fault 分批,
        // attachment snapshot 紧接着读 transient 字段 → 不会拉出 imagesData blob。
        allEntriesRequest.fetchBatchSize = 200
        let entries: [DiaryEntry]
        do {
            entries = try viewContext.fetch(allEntriesRequest)
        } catch {
            Log.error("[SettingsView] 删除前重新 fetch 失败: \(error)", category: .ui)
            return false
        }

        // DiaryEntry 删完后,AskPast citations / narrative 回顾都不再有可靠引用目标。
        // 全删语义下把 AIConversation 一并清空,避免历史回答留下悬空引用。
        let conversationRequest = NSFetchRequest<AIConversation>(entityName: "AIConversation")
        let conversations: [AIConversation]
        do {
            conversations = try viewContext.fetch(conversationRequest)
        } catch {
            Log.error("[SettingsView] 删除 AI 会话前 fetch 失败: \(error)", category: .ui)
            viewContext.rollback()
            return false
        }

        let attachmentSnapshots = entries.map {
            EntryAttachmentSnapshot(imageFileNames: $0.imageFileNameArray, audioFileName: $0.audioFileName)
        }
        for entry in entries {
            viewContext.delete(entry)
        }
        for conversation in conversations {
            viewContext.delete(conversation)
        }
        do {
            try viewContext.save()
            // 五件套清理走统一入口(EntryWipeOrchestrator) — 见该文件 doc。
            await EntryWipeOrchestrator.performBulkWipeCleanup()
        } catch {
            Log.error("[SettingsView] 删除所有日记失败: \(error)", category: .ui)
            viewContext.rollback()
            return false
        }

        #if canImport(UIKit)
        let backgroundTask = SettingsBulkWipeBackgroundTaskHolder()
        backgroundTask.id = UIApplication.shared.beginBackgroundTask(withName: "LumorySettingsBulkWipeAttachmentCleanup") {
            Log.warning("[SettingsView] bulk-wipe attachment cleanup background task expired", category: .persistence)
            endSettingsBulkWipeBackgroundTask(backgroundTask)
        }
        defer {
            endSettingsBulkWipeBackgroundTask(backgroundTask)
        }
        #endif

        await Task.detached(priority: .utility) {
            for snapshot in attachmentSnapshots {
                for fileName in snapshot.imageFileNames {
                    do {
                        try DiaryEntry.deleteImageFromDocuments(fileName)
                    } catch {
                        Log.error("[SettingsView] 删除图片附件失败 \(fileName): \(error)", category: .ui)
                    }
                }
                if let audioFileName = snapshot.audioFileName, !audioFileName.isEmpty {
                    DiaryEntry.deleteAudioFromDocuments(audioFileName)
                }
            }
        }.value
        return true
    }
}

private struct EntryAttachmentSnapshot: Sendable {
    let imageFileNames: [String]
    let audioFileName: String?
}

#if canImport(UIKit)
@MainActor
private final class SettingsBulkWipeBackgroundTaskHolder {
    var id: UIBackgroundTaskIdentifier = .invalid
}

@MainActor
private func endSettingsBulkWipeBackgroundTask(_ holder: SettingsBulkWipeBackgroundTaskHolder) {
    guard holder.id != .invalid else { return }
    UIApplication.shared.endBackgroundTask(holder.id)
    holder.id = .invalid
}
#endif
