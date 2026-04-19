import Foundation
import CoreData
import CloudKit

@available(iOS 13.0, macOS 10.15, *)
class CloudKitSyncMonitor: ObservableObject {
    @Published var syncStatus: SyncStatus = .unknown
    @Published var lastSyncDate: Date?
    @Published var errorMessage: String?
    
    private let container: NSPersistentCloudKitContainer
    
    enum SyncStatus: String, CaseIterable {
        case unknown = "Unknown"
        case syncing = "Syncing"
        case synced = "Synced"
        case error = "Error"
        case notSignedIn = "Not Signed In"
        case networkUnavailable = "Network Unavailable"
        
        var displayName: String {
            switch self {
            case .unknown: return "Unknown"
            case .syncing: return "Syncing..."
            case .synced: return "Synced"
            case .error: return "Sync Error"
            case .notSignedIn: return "Not Signed In to iCloud"
            case .networkUnavailable: return "Network Unavailable"
            }
        }
        
        var iconName: String {
            switch self {
            case .unknown: return "questionmark.circle"
            case .syncing: return "arrow.triangle.2.circlepath"
            case .synced: return "checkmark.circle"
            case .error: return "exclamationmark.triangle"
            case .notSignedIn: return "person.crop.circle.badge.xmark"
            case .networkUnavailable: return "wifi.slash"
            }
        }
    }
    
    init(container: NSPersistentCloudKitContainer) {
        self.container = container
        setupNotifications()
        checkCloudKitStatus()
    }
    
    private func setupNotifications() {
        // 监听远程变化
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            Log.info("[CloudKitSyncMonitor] Remote changes detected", category: .sync)
            self?.syncStatus = .synced
            self?.lastSyncDate = Date()
            self?.errorMessage = nil
        }


        // 监听Core Data保存通知
        NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: container.viewContext,
            queue: .main
        ) { [weak self] notification in
            // Only react to saves that actually have changes
            guard let context = notification.object as? NSManagedObjectContext else {
                return
            }

            let insertedObjects = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>
            let updatedObjects = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject>
            let deletedObjects = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject>

            let hasInserts = insertedObjects?.isEmpty == false
            let hasUpdates = updatedObjects?.isEmpty == false
            let hasDeletes = deletedObjects?.isEmpty == false

            guard context.hasChanges || hasInserts || hasUpdates || hasDeletes else {
                return
            }

            Log.info("[CloudKitSyncMonitor] Local changes saved, initiating CloudKit sync", category: .sync)
            self?.syncStatus = .syncing
            self?.errorMessage = nil

            // Give CloudKit some time to process the changes
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                // Only update to synced if we're still in syncing state
                if self?.syncStatus == .syncing {
                    self?.syncStatus = .synced
                    self?.lastSyncDate = Date()
                }
            }
        }

        // 监听CloudKit容器事件 (iOS 14+ / macOS 11+)
        if #available(iOS 14.0, macOS 11.0, *) {
            NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: container,
                queue: .main
            ) { [weak self] notification in
                if let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event {
                    self?.handleCloudKitEvent(event)
                }
            }
        }
    }

    @available(iOS 14.0, macOS 11.0, *)
    private func handleCloudKitEvent(_ event: NSPersistentCloudKitContainer.Event) {
        Log.info("[CloudKitSyncMonitor] CloudKit event: \(event.type.rawValue), succeeded: \(event.succeeded)", category: .sync)

        switch event.type {
        case .setup:
            if event.succeeded {
                Log.info("[CloudKitSyncMonitor] CloudKit setup completed successfully", category: .sync)
                syncStatus = .synced
                errorMessage = nil
            } else {
                Log.error("[CloudKitSyncMonitor] CloudKit setup failed: \(event.error?.localizedDescription ?? "Unknown error")", category: .sync)
                syncStatus = .error
                errorMessage = "CloudKit setup failed: \(event.error?.localizedDescription ?? "Unknown error")"
            }

        case .import:
            if event.succeeded {
                Log.info("[CloudKitSyncMonitor] CloudKit import completed successfully", category: .sync)
                syncStatus = .synced
                lastSyncDate = Date()
                errorMessage = nil
            } else {
                Log.error("[CloudKitSyncMonitor] CloudKit import failed: \(event.error?.localizedDescription ?? "Unknown error")", category: .sync)
                syncStatus = .error
                errorMessage = "Import failed: \(event.error?.localizedDescription ?? "Unknown error")"
            }

        case .export:
            if event.succeeded {
                Log.info("[CloudKitSyncMonitor] CloudKit export completed successfully", category: .sync)
                syncStatus = .synced
                lastSyncDate = Date()
                errorMessage = nil
            } else {
                Log.error("[CloudKitSyncMonitor] CloudKit export failed: \(event.error?.localizedDescription ?? "Unknown error")", category: .sync)
                syncStatus = .error
                errorMessage = "Export failed: \(event.error?.localizedDescription ?? "Unknown error")"
            }

        @unknown default:
            Log.info("[CloudKitSyncMonitor] Unknown CloudKit event type", category: .sync)
        }
    }
    
    func checkCloudKitStatus() {
        let ckContainer = CKContainer(identifier: "iCloud.com.Mingyi.Lumory")

        // First check account status
        ckContainer.accountStatus { [weak self] status, error in
            DispatchQueue.main.async {
                if let error = error {
                    Log.error("[CloudKitSyncMonitor] Account status error: \(error)", category: .sync)
                    self?.syncStatus = .error
                    self?.errorMessage = "iCloud account error: \(error.localizedDescription)"
                    return
                }

                switch status {
                case .available:
                    // Account is available, now check database accessibility
                    self?.checkDatabaseAccessibility(container: ckContainer)
                case .noAccount:
                    self?.syncStatus = .notSignedIn
                    self?.errorMessage = "Please sign in to iCloud in System Settings"
                case .restricted:
                    self?.syncStatus = .notSignedIn
                    self?.errorMessage = "iCloud access is restricted"
                case .couldNotDetermine:
                    self?.syncStatus = .unknown
                    self?.errorMessage = "Could not determine iCloud status"
                case .temporarilyUnavailable:
                    self?.syncStatus = .networkUnavailable
                    self?.errorMessage = "iCloud temporarily unavailable"
                @unknown default:
                    self?.syncStatus = .unknown
                    self?.errorMessage = "Unknown iCloud status"
                }
            }
        }
    }

    private func checkDatabaseAccessibility(container: CKContainer) {
        // Test database accessibility by performing a simple query.
        // 之前用 `NSPredicate(value: true)` —— 这个谓词如果没有对应的 query index 会在
        // production schema 被 CloudKit 拒掉（`CKError.invalidArguments`），然后用户一直
        // 看到 `.error` 状态。换成 `modificationDate > distantPast` 这种必然存在 built-in
        // 索引的谓词，既能检测可达性，又不依赖 schema-level query index。
        let database = container.privateCloudDatabase
        let query = CKQuery(
            recordType: "CD_DiaryEntry",
            predicate: NSPredicate(format: "modificationDate > %@", Date.distantPast as NSDate)
        )
        query.sortDescriptors = [NSSortDescriptor(key: "CD_date", ascending: false)]

        if #available(macOS 12.0, iOS 15.0, *) {
            database.fetch(withQuery: query, inZoneWith: nil, desiredKeys: nil, resultsLimit: 1) { [weak self] result in
                switch result {
                case .success(let (matchResults, _)):
                    // Convert to the expected format
                    let records = matchResults.compactMap { try? $0.1.get() }
                    self?.handleDatabaseQueryResult(records: records, error: nil)
                case .failure(let error):
                    self?.handleDatabaseQueryResult(records: nil, error: error)
                }
            }
        } else {
            database.perform(query, inZoneWith: nil) { [weak self] records, error in
                self?.handleDatabaseQueryResult(records: records, error: error)
            }
        }
    }

    private func handleDatabaseQueryResult(records: [CKRecord]?, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            if let error = error {
                let ckError = error as? CKError
                switch ckError?.code {
                case .networkUnavailable, .networkFailure:
                    self?.syncStatus = .networkUnavailable
                    self?.errorMessage = "Network unavailable for iCloud sync"
                case .notAuthenticated:
                    self?.syncStatus = .notSignedIn
                    self?.errorMessage = "Please sign in to iCloud"
                case .quotaExceeded:
                    self?.syncStatus = .error
                    self?.errorMessage = "iCloud storage quota exceeded"
                case .zoneNotFound, .userDeletedZone:
                    // This is expected for new installations
                    Log.info("[CloudKitSyncMonitor] Zone not found (expected for new installations)", category: .sync)
                    self?.syncStatus = .synced
                    self?.errorMessage = nil
                default:
                    Log.error("[CloudKitSyncMonitor] Database access error: \(error)", category: .sync)
                    self?.syncStatus = .error
                    self?.errorMessage = "iCloud sync error: \(error.localizedDescription)"
                }
            } else {
                // Database is accessible
                self?.syncStatus = .synced
                self?.errorMessage = nil
                Log.info("[CloudKitSyncMonitor] CloudKit database accessible, sync ready", category: .sync)
            }
        }
    }

    /// @MainActor 强制：`viewContext` 是 `.mainQueueConcurrencyType`，Core Data 明确要求
    /// 必须在主线程 / 主队列访问。此函数原来没做线程约束——HomeView pull-to-refresh 用
    /// `Task.detached` 调过来就是活的 Core Data 线程违规，随机静默损坏对象图。
    @MainActor
    func forceSync() {
        Log.info("[CloudKitSyncMonitor] Force sync initiated", category: .sync)
        syncStatus = .syncing
        errorMessage = nil

        // Trigger Core Data save to push changes to CloudKit
        let context = container.viewContext
        if context.hasChanges {
            do {
                try context.save()
                Log.info("[CloudKitSyncMonitor] Local changes saved, triggering CloudKit sync", category: .sync)
            } catch {
                syncStatus = .error
                errorMessage = "Failed to save local changes: \(error.localizedDescription)"
                return
            }
        }

        // Check CloudKit status and wait for sync completion
        checkCloudKitStatusAndWaitForSync()
    }

    private func checkCloudKitStatusAndWaitForSync() {
        let ckContainer = CKContainer(identifier: "iCloud.com.Mingyi.Lumory")

        ckContainer.accountStatus { [weak self] status, error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.syncStatus = .error
                    self?.errorMessage = "Account check failed: \(error.localizedDescription)"
                }
                return
            }

            guard status == .available else {
                DispatchQueue.main.async {
                    self?.syncStatus = .notSignedIn
                    self?.errorMessage = "iCloud account not available"
                }
                return
            }

            // Wait a moment for CloudKit to process the changes
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.verifySync()
            }
        }
    }

    private func verifySync() {
        // Perform a simple query to verify CloudKit connectivity
        let ckContainer = CKContainer(identifier: "iCloud.com.Mingyi.Lumory")
        let database = ckContainer.privateCloudDatabase
        // **必须**和 checkDatabaseAccessibility 用同一个谓词——production schema 下
        // `NSPredicate(value: true)` 没有对应的 query index，CloudKit 会直接 invalidArguments，
        // 让 `forceSync` → pull-to-refresh 永远翻到 .error 即使 CloudKit 是健康的。
        // modificationDate > distantPast 有 built-in 索引，既能验可达性又不依赖 schema query index。
        let query = CKQuery(
            recordType: "CD_DiaryEntry",
            predicate: NSPredicate(format: "modificationDate > %@", Date.distantPast as NSDate)
        )
        query.sortDescriptors = [NSSortDescriptor(key: "CD_date", ascending: false)]

        if #available(macOS 12.0, iOS 15.0, *) {
            database.fetch(withQuery: query, inZoneWith: nil, desiredKeys: nil, resultsLimit: 1) { [weak self] result in
                switch result {
                case .success(let (matchResults, _)):
                    // Convert to the expected format
                    let records = matchResults.compactMap { try? $0.1.get() }
                    self?.handleSyncVerificationResult(records: records, error: nil)
                case .failure(let error):
                    self?.handleSyncVerificationResult(records: nil, error: error)
                }
            }
        } else {
            database.perform(query, inZoneWith: nil) { [weak self] records, error in
                self?.handleSyncVerificationResult(records: records, error: error)
            }
        }
    }

    private func handleSyncVerificationResult(records: [CKRecord]?, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            if let error = error {
                let ckError = error as? CKError
                if ckError?.code == .zoneNotFound || ckError?.code == .userDeletedZone {
                    // This is normal for new installations
                    self?.syncStatus = .synced
                    self?.lastSyncDate = Date()
                    self?.errorMessage = nil
                    Log.info("[CloudKitSyncMonitor] Sync verified (new installation)", category: .sync)
                } else {
                    self?.syncStatus = .error
                    self?.errorMessage = "Sync verification failed: \(error.localizedDescription)"
                    Log.error("[CloudKitSyncMonitor] Sync verification error: \(error)", category: .sync)
                }
            } else {
                self?.syncStatus = .synced
                self?.lastSyncDate = Date()
                self?.errorMessage = nil
                Log.info("[CloudKitSyncMonitor] Sync verified successfully", category: .sync)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}