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
