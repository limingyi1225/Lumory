import Foundation
import CoreData
import CloudKit
#if canImport(UIKit)
import UIKit
#endif

final class DatabaseRecoveryService {
    static let shared = DatabaseRecoveryService()

    private init() {}

    static let sqliteSidecarExtensions = ["sqlite-wal", "sqlite-shm", "sqlite-ck"]

    enum RecoveryError: LocalizedError {
        case backupFailed
        case recoveryFailed
        case noBackupAvailable

        var errorDescription: String? {
            switch self {
            case .backupFailed:
                return "Failed to create database backup"
            case .recoveryFailed:
                return "Failed to recover database"
            case .noBackupAvailable:
                return "No backup available for recovery"
            }
        }
    }

    // 注：以前这里有 checkDatabaseHealth(at:) 跑 `PRAGMA integrity_check`，
    // 但 WAL 模式下 SQLite 打开被 CoreData 锁住的 store 很容易误报 corrupt，
    // 且启动路径的 integrity_check 本身成本高，已经从启动流程移除，函数也随之删除。

    func performRecovery(for container: NSPersistentCloudKitContainer, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let storeURL = container.persistentStoreDescriptions.first?.url else {
            completion(.failure(RecoveryError.recoveryFailed))
            return
        }
        
        // Show recovery alert
        DispatchQueue.main.async {
            self.showRecoveryAlert { shouldProceed in
                if shouldProceed {
                    self.executeRecovery(storeURL: storeURL, container: container, completion: completion)
                } else {
                    completion(.failure(RecoveryError.recoveryFailed))
                }
            }
        }
    }
    
    private func executeRecovery(
        storeURL: URL,
        container: NSPersistentCloudKitContainer,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let coordinator = container.persistentStoreCoordinator
        
        // Create backup first. If this fails, do not delete the only local copy.
        guard let backupURL = createBackup(of: storeURL) else {
            completion(.failure(RecoveryError.backupFailed))
            return
        }
        
        // Remove all stores
        for store in coordinator.persistentStores {
            do {
                try coordinator.remove(store)
                Log.info("[DatabaseRecovery] Removed store: \(store.url?.path ?? "unknown")", category: .persistence)
            } catch {
                Log.error("[DatabaseRecovery] Failed to remove store: \(error)", category: .persistence)
                completion(.failure(error))
                return
            }
        }
        
        // Delete corrupted files
        deleteCorruptedFiles(at: storeURL)
        
        // Recreate the store
        container.loadPersistentStores { _, error in
            if let error = error {
                Log.error("[DatabaseRecovery] Failed to recreate store: \(error)", category: .persistence)
                
                // Try to restore from backup if recreation fails
                self.restoreFromBackup(backupURL: backupURL, to: storeURL)
                container.loadPersistentStores { _, retryError in
                    if let retryError = retryError {
                        completion(.failure(retryError))
                    } else {
                        Log.info("[DatabaseRecovery] Successfully restored store from backup", category: .persistence)
                        self.completeRestoreRecovery(container: container, completion: completion)
                    }
                }
            } else {
                Log.info("[DatabaseRecovery] Successfully recreated store", category: .persistence)
                self.completeRecreateRecovery(container: container, completion: completion)
            }
        }
    }

    private func completeRecreateRecovery(
        container: NSPersistentCloudKitContainer,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        // Trigger CloudKit sync to restore data
        triggerCloudKitSync(container: container)

        // **Completion 在 cleanup 完成后 fire**:之前 completion 跟 cleanup 同帧 fire,用户在 cleanup
        // 完成之前杀 App / 锁屏会让派生缓存(Reminder / ThemeAlias / Prompt / Insights / Widget)
        // 停在 stale 状态。recovery 是几秒钟流程,多等 ms 级 cleanup 不影响 UX,但保证 completion
        // 回去时所有派生 state 已重置。
        // 注:CK 后续 import 触发 `PersistenceController` 的 RemoteChange observer → 重新 schedule
        // widget snapshot refresh,作为额外 self-heal 兜底。
        Task { @MainActor in
            NotificationCenter.default.post(name: .databaseRecreated, object: nil)
            await EntryWipeOrchestrator.performBulkWipeCleanup()
            completion(.success(()))
        }
    }

    private func completeRestoreRecovery(
        container: NSPersistentCloudKitContainer,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        // Backup restore means the store may already contain entries. Do not reuse the bulk-wipe path:
        // it would reset alias state and write an empty widget snapshot over restored content.
        triggerCloudKitSync(container: container)

        Task { @MainActor in
            NotificationCenter.default.post(name: .databaseRecreated, object: nil)
            ReminderService.shared.requestReschedule()
            PromptSuggestionEngine.shared.clearCache()
            InsightsResultCache.shared.clear()
            await ThemeAliasResolver.shared.cleanupOrphanedPending()
            await WidgetSnapshotService.shared.invalidateCaches()
            await WidgetSnapshotService.shared.requestRefresh(container: container, bypassDebounce: true)
            completion(.success(()))
        }
    }
    
    func createBackup(of url: URL) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            Log.error("[DatabaseRecovery] documentDirectory unavailable, cannot create backup", category: .persistence)
            return nil
        }
        let backupDir = docs.appendingPathComponent("DatabaseBackups", isDirectory: true)
        return createBackup(of: url, in: backupDir)
    }

    func createBackup(of url: URL, in backupDir: URL) -> URL? {
        let timestamp = Int(Date().timeIntervalSince1970)

        // Create backup directory if needed
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let backupURL = backupDir.appendingPathComponent("backup-\(timestamp).sqlite")

        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
            Log.info("[DatabaseRecovery] Created backup at: \(backupURL.path)", category: .persistence)

            // Also backup related files
            for ext in Self.sqliteSidecarExtensions {
                let sourceFile = url.deletingPathExtension().appendingPathExtension(ext)
                let backupFile = backupURL.deletingPathExtension().appendingPathExtension(ext)
                try? FileManager.default.copyItem(at: sourceFile, to: backupFile)
            }

            return backupURL
        } catch {
            Log.error("[DatabaseRecovery] Failed to create backup: \(error)", category: .persistence)
            return nil
        }
    }

    func deleteCorruptedFiles(at url: URL) {
        let fileManager = FileManager.default

        // Delete main database file
        try? fileManager.removeItem(at: url)

        // Delete related files
        for ext in Self.sqliteSidecarExtensions {
            let file = url.deletingPathExtension().appendingPathExtension(ext)
            try? fileManager.removeItem(at: file)
        }

        Log.info("[DatabaseRecovery] Deleted corrupted database files", category: .persistence)
    }

    func restoreFromBackup(backupURL: URL, to targetURL: URL) {
        do {
            try? FileManager.default.removeItem(at: targetURL)
            try FileManager.default.copyItem(at: backupURL, to: targetURL)
            Log.info("[DatabaseRecovery] Restored from backup", category: .persistence)

            // Mirror createBackup: also restore -wal / -shm / -ck 兄弟文件。
            // checkpoint 干净时它们可能不存在，所以全部 try?。
            for ext in Self.sqliteSidecarExtensions {
                let backupSibling = backupURL.deletingPathExtension().appendingPathExtension(ext)
                let targetSibling = targetURL.deletingPathExtension().appendingPathExtension(ext)
                try? FileManager.default.removeItem(at: targetSibling)
                try? FileManager.default.copyItem(at: backupSibling, to: targetSibling)
            }
        } catch {
            Log.error("[DatabaseRecovery] Failed to restore from backup: \(error)", category: .persistence)
        }
    }
    
    private func triggerCloudKitSync(container: NSPersistentCloudKitContainer) {
        // 历史版本用"插一条空 DiaryEntry 再 delete"来戳 CloudKit，
        // 第二次 save（delete）失败时会让空白日记同步到所有设备。
        // 现在改成只读地让 CKContainer 拉一次 zone 列表 —— `NSPersistentCloudKitContainer`
        // 的 mirror 会顺势检查 pending changes，达到同样的"戳一下"效果，零脏数据风险。
        let ckContainer = CKContainer(identifier: "iCloud.com.Mingyi.Lumory")
        ckContainer.privateCloudDatabase.fetchAllRecordZones { zones, error in
            if let error {
                Log.error("[DatabaseRecovery] CloudKit zone fetch failed: \(error)", category: .persistence)
            } else {
                Log.info("[DatabaseRecovery] Triggered CloudKit sync — zones=\(zones?.count ?? 0)", category: .persistence)
            }
        }
    }
    
    private func showRecoveryAlert(completion: @escaping (Bool) -> Void) {
        let foregroundScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let windowScene = foregroundScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first,
              let rootViewController = window.rootViewController else {
            // **关键数据安全**：以前这条 fall-through 是 `completion(true)`——
            // 多窗口 iPad / 场景 teardown race 下 rootViewController 为 nil 时，
            // 会在用户看不到任何弹窗的情况下直接抹掉本地数据库。
            // 改成 `completion(false)`：取消这次 recovery，让下一次"有 UI 的"启动再确认。
            // 等不到 UI 的宁可暂时不 recover，也不能静默删用户数据。
            Log.error(
                "[DatabaseRecovery] No window available for confirmation alert — ABORTING recovery to avoid silent data loss",
                category: .persistence
            )
            completion(false)
            return
        }

        let alert = UIAlertController(
            title: NSLocalizedString("数据库需要修复", comment: "DB recovery alert title"),
            message: NSLocalizedString(
                "数据库可能已损坏。修复会删除本地数据库文件,然后从 iCloud 重新拉取。⚠️ 还没同步到 iCloud 的本地日记可能会丢失(自动备份保留在 App 内,联系开发者可恢复)。修复过程也会重置已合并的主题别名分组。",
                comment: "DB recovery alert body"
            ),
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(
            title: NSLocalizedString("取消", comment: "Cancel"),
            style: .cancel
        ) { _ in
            completion(false)
        })

        alert.addAction(UIAlertAction(
            title: NSLocalizedString("修复", comment: "DB recovery confirm"),
            style: .default
        ) { _ in
            completion(true)
        })

        var topController = rootViewController
        while let presentedViewController = topController.presentedViewController {
            topController = presentedViewController
        }

        topController.present(alert, animated: true)
    }
    
    func cleanupOldBackups(keepLast: Int = 3) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            Log.error("[DatabaseRecovery] documentDirectory unavailable, skipping backup cleanup", category: .persistence)
            return
        }
        let backupDir = docs.appendingPathComponent("DatabaseBackups", isDirectory: true)

        cleanupOldBackups(in: backupDir, keepLast: keepLast)
    }

    func cleanupOldBackups(in backupDir: URL, keepLast: Int = 3) {
        do {
            let backups = try FileManager.default.contentsOfDirectory(
                at: backupDir,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            ).filter { $0.pathExtension == "sqlite" }
                .sorted { url1, url2 in
                    let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                    let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                    return date1 > date2
                }
            
            // Keep only the most recent backups
            if backups.count > keepLast {
                for backup in backups.dropFirst(keepLast) {
                    try FileManager.default.removeItem(at: backup)

                    // Also remove related files
                    for ext in Self.sqliteSidecarExtensions {
                        let file = backup.deletingPathExtension().appendingPathExtension(ext)
                        try? FileManager.default.removeItem(at: file)
                    }
                }

                Log.info("[DatabaseRecovery] Cleaned up \(backups.count - keepLast) old backups", category: .persistence)
            }
        } catch {
            Log.error("[DatabaseRecovery] Failed to cleanup old backups: \(error)", category: .persistence)
        }
    }
}
