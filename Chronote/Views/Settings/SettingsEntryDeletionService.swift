import CoreData

@MainActor
enum SettingsEntryDeletionService {
    static func deleteAll(entries: [DiaryEntry], viewContext: NSManagedObjectContext) async -> Bool {
        // **P1 fix (2026-05-13 superreview round 2)**:原顺序"delete + save → 之后 await
        // performBulkWipeCleanup 内才 cancelPending",中间窗口 NarrativePrecompute 在飞 task
        // 可能正在写 fresh narrative,delete + save 完成后才被 bulk wipe 后续 clear 绕弯抓。
        // **先 cancel + bump generation,再 delete + save** —— 让 bg writer 在 actor 守卫前
        // 停掉。performBulkWipeCleanup 内也仍调一次 cancel(幂等,无害)。
        await NarrativePrecomputeService.shared.cancelPendingAndBumpGeneration()

        let attachmentSnapshots = entries.map {
            EntryAttachmentSnapshot(imageFileNames: $0.imageFileNameArray, audioFileName: $0.audioFileName)
        }
        for entry in entries {
            viewContext.delete(entry)
        }
        // DiaryEntry 删完后,AskPast citations / narrative 回顾都不再有可靠引用目标。
        // 全删语义下把 AIConversation 一并清空,避免历史回答留下悬空引用。
        let conversationRequest = NSFetchRequest<AIConversation>(entityName: "AIConversation")
        if let conversations = try? viewContext.fetch(conversationRequest) {
            for conversation in conversations {
                viewContext.delete(conversation)
            }
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
