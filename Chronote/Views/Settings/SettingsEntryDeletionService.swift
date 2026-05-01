import CoreData

@MainActor
enum SettingsEntryDeletionService {
    static func deleteAll(entries: [DiaryEntry], viewContext: NSManagedObjectContext) async -> Bool {
        let attachmentSnapshots = entries.map {
            EntryAttachmentSnapshot(imageFileNames: $0.imageFileNameArray, audioFileName: $0.audioFileName)
        }
        for entry in entries {
            viewContext.delete(entry)
        }
        do {
            try viewContext.save()
            // 批量删除会改变当前周期是否已完成,需要立刻重排本地提醒。
            ReminderService.shared.requestReschedule()
            // 清掉 alias resolver state(pending / groups / coolUntil)+ prompt cache,
            // 否则 banner 还会弹引用已删 entry 的建议、ReminderService 通知 body 还会引用
            // 已死主题词。negativePairs 保留(用户主观判断与 entry 存在与否无关)。
            ThemeAliasResolver.shared.resetForBulkEntryWipe()
            PromptSuggestionEngine.shared.clearCache()
            InsightsResultCache.shared.clear()
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
