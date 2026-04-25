import Foundation
import CoreData
import CloudKit
#if canImport(UIKit)
import UIKit
#endif

final class DatabaseRecoveryService {
    static let shared = DatabaseRecoveryService()

    private init() {}

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
        
        // Create backup first
        let backupURL = createBackup(of: storeURL)
        
        // Remove all stores
        for store in coordinator.persistentStores {
            do {
                try coordinator.remove(store)
                Log.info("[DatabaseRecovery] Removed store: \(store.url?.path ?? "unknown")", category: .persistence)
            } catch {
                Log.error("[DatabaseRecovery] Failed to remove store: \(error)", category: .persistence)
            }
        }
        
        // Delete corrupted files
        deleteCorruptedFiles(at: storeURL)
        
        // Recreate the store
        container.loadPersistentStores { _, error in
            if let error = error {
                Log.error("[DatabaseRecovery] Failed to recreate store: \(error)", category: .persistence)
                
                // Try to restore from backup if recreation fails
                if let backupURL = backupURL {
                    self.restoreFromBackup(backupURL: backupURL, to: storeURL)
                    container.loadPersistentStores { _, retryError in
                        if let retryError = retryError {
                            completion(.failure(retryError))
                        } else {
                            completion(.success(()))
                        }
                    }
                } else {
                    completion(.failure(error))
                }
            } else {
                Log.info("[DatabaseRecovery] Successfully recreated store", category: .persistence)
                
                // Trigger CloudKit sync to restore data
                self.triggerCloudKitSync(container: container)
                
                // Post notification for UI refresh
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .databaseRecreated, object: nil)
                }
                
                completion(.success(()))
            }
        }
    }
    
    private func createBackup(of url: URL) -> URL? {
        let timestamp = Int(Date().timeIntervalSince1970)
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            Log.error("[DatabaseRecovery] documentDirectory unavailable, cannot create backup", category: .persistence)
            return nil
        }
        let backupDir = docs.appendingPathComponent("DatabaseBackups", isDirectory: true)
        
        // Create backup directory if needed
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        
        let backupURL = backupDir.appendingPathComponent("backup-\(timestamp).sqlite")
        
        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
            Log.info("[DatabaseRecovery] Created backup at: \(backupURL.path)", category: .persistence)
            
            // Also backup related files
            let extensions = ["sqlite-wal", "sqlite-shm"]
            for ext in extensions {
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
    
    private func deleteCorruptedFiles(at url: URL) {
        let fileManager = FileManager.default
        
        // Delete main database file
        try? fileManager.removeItem(at: url)
        
        // Delete related files
        let extensions = ["sqlite-wal", "sqlite-shm", "sqlite-ck"]
        for ext in extensions {
            let file = url.deletingPathExtension().appendingPathExtension(ext)
            try? fileManager.removeItem(at: file)
        }
        
        Log.info("[DatabaseRecovery] Deleted corrupted database files", category: .persistence)
    }
    
    private func restoreFromBackup(backupURL: URL, to targetURL: URL) {
        do {
            try FileManager.default.copyItem(at: backupURL, to: targetURL)
            Log.info("[DatabaseRecovery] Restored from backup", category: .persistence)

            // Mirror createBackup: also restore -wal / -shm 兄弟文件。
            // checkpoint 干净时它们可能不存在，所以全部 try?。
            let extensions = ["sqlite-wal", "sqlite-shm"]
            for ext in extensions {
                let backupSibling = backupURL.deletingPathExtension().appendingPathExtension(ext)
                let targetSibling = targetURL.deletingPathExtension().appendingPathExtension(ext)
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
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
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
            title: "Database Recovery Required",
            message: "Your diary database appears to be corrupted. Would you like to attempt recovery? "
                + "Your data will be restored from iCloud if available.",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completion(false)
        })

        alert.addAction(UIAlertAction(title: "Recover", style: .default) { _ in
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
                    let extensions = ["sqlite-wal", "sqlite-shm"]
                    for ext in extensions {
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
