import Foundation
import CoreData
import CloudKit
import SQLite3
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
    
    func checkDatabaseHealth(at url: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }
        
        // Basic integrity check using SQLite
        var db: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { 
            if let db = db {
                sqlite3_close(db)
            }
        }
        
        if result != SQLITE_OK || db == nil {
            return false
        }
        
        // Run integrity check
        var statement: OpaquePointer?
        let sql = "PRAGMA integrity_check;"
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(statement) }
            
            if sqlite3_step(statement) == SQLITE_ROW {
                if let result = sqlite3_column_text(statement, 0) {
                    let resultString = String(cString: result)
                    return resultString == "ok"
                }
            }
        }
        
        return false
    }
    
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
    
    private func executeRecovery(storeURL: URL, container: NSPersistentCloudKitContainer, completion: @escaping (Result<Void, Error>) -> Void) {
        let coordinator = container.persistentStoreCoordinator
        
        // Create backup first
        let backupURL = createBackup(of: storeURL)
        
        // Remove all stores
        for store in coordinator.persistentStores {
            do {
                try coordinator.remove(store)
                print("[DatabaseRecovery] Removed store: \(store.url?.path ?? "unknown")")
            } catch {
                print("[DatabaseRecovery] Failed to remove store: \(error)")
            }
        }
        
        // Delete corrupted files
        deleteCorruptedFiles(at: storeURL)
        
        // Recreate the store
        container.loadPersistentStores { storeDescription, error in
            if let error = error {
                print("[DatabaseRecovery] Failed to recreate store: \(error)")
                
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
                print("[DatabaseRecovery] Successfully recreated store")
                
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
        let backupDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DatabaseBackups", isDirectory: true)
        
        // Create backup directory if needed
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        
        let backupURL = backupDir.appendingPathComponent("backup-\(timestamp).sqlite")
        
        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
            print("[DatabaseRecovery] Created backup at: \(backupURL.path)")
            
            // Also backup related files
            let extensions = ["sqlite-wal", "sqlite-shm"]
            for ext in extensions {
                let sourceFile = url.deletingPathExtension().appendingPathExtension(ext)
                let backupFile = backupURL.deletingPathExtension().appendingPathExtension(ext)
                try? FileManager.default.copyItem(at: sourceFile, to: backupFile)
            }
            
            return backupURL
        } catch {
            print("[DatabaseRecovery] Failed to create backup: \(error)")
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
        
        print("[DatabaseRecovery] Deleted corrupted database files")
    }
    
    private func restoreFromBackup(backupURL: URL, to targetURL: URL) {
        do {
            try FileManager.default.copyItem(at: backupURL, to: targetURL)
            print("[DatabaseRecovery] Restored from backup")
        } catch {
            print("[DatabaseRecovery] Failed to restore from backup: \(error)")
        }
    }
    
    private func triggerCloudKitSync(container: NSPersistentCloudKitContainer) {
        // Force a sync by creating a dummy change
        let context = container.viewContext
        let entity = NSEntityDescription.entity(forEntityName: "DiaryEntry", in: context)!
        let entry = NSManagedObject(entity: entity, insertInto: context)
        
        // Set required fields
        entry.setValue(UUID(), forKey: "id")
        entry.setValue(Date(), forKey: "date")
        entry.setValue("", forKey: "text")
        entry.setValue(0.5, forKey: "moodValue")
        
        // Save and immediately delete to trigger sync
        do {
            try context.save()
            context.delete(entry)
            try context.save()
            print("[DatabaseRecovery] Triggered CloudKit sync")
        } catch {
            print("[DatabaseRecovery] Failed to trigger sync: \(error)")
        }
    }
    
    private func showRecoveryAlert(completion: @escaping (Bool) -> Void) {
        #if os(iOS) || targetEnvironment(macCatalyst)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let rootViewController = window.rootViewController else {
            print("[DatabaseRecovery] No window available for alert, proceeding with recovery")
            completion(true)
            return
        }
        
        let alert = UIAlertController(
            title: "Database Recovery Required",
            message: "Your diary database appears to be corrupted. Would you like to attempt recovery? Your data will be restored from iCloud if available.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completion(false)
        })
        
        alert.addAction(UIAlertAction(title: "Recover", style: .default) { _ in
            completion(true)
        })
        
        // Present from the topmost view controller
        var topController = rootViewController
        while let presentedViewController = topController.presentedViewController {
            topController = presentedViewController
        }
        
        topController.present(alert, animated: true)
        #else
        // For macOS native, we would use NSAlert but since this is a Mac Catalyst app, the above code will work
        completion(true)
        #endif
    }
    
    func cleanupOldBackups(keepLast: Int = 3) {
        let backupDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DatabaseBackups", isDirectory: true)
        
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
                
                print("[DatabaseRecovery] Cleaned up \(backups.count - keepLast) old backups")
            }
        } catch {
            print("[DatabaseRecovery] Failed to cleanup old backups: \(error)")
        }
    }
}