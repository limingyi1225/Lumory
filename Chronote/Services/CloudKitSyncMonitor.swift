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
            print("[CloudKitSyncMonitor] Remote changes detected")
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

            print("[CloudKitSyncMonitor] Local changes saved, initiating CloudKit sync")
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
        print("[CloudKitSyncMonitor] CloudKit event: \(event.type.rawValue), succeeded: \(event.succeeded)")

        switch event.type {
        case .setup:
            if event.succeeded {
                print("[CloudKitSyncMonitor] CloudKit setup completed successfully")
                syncStatus = .synced
                errorMessage = nil
            } else {
                print("[CloudKitSyncMonitor] CloudKit setup failed: \(event.error?.localizedDescription ?? "Unknown error")")
                syncStatus = .error
                errorMessage = "CloudKit setup failed: \(event.error?.localizedDescription ?? "Unknown error")"
            }

        case .import:
            if event.succeeded {
                print("[CloudKitSyncMonitor] CloudKit import completed successfully")
                syncStatus = .synced
                lastSyncDate = Date()
                errorMessage = nil
            } else {
                print("[CloudKitSyncMonitor] CloudKit import failed: \(event.error?.localizedDescription ?? "Unknown error")")
                syncStatus = .error
                errorMessage = "Import failed: \(event.error?.localizedDescription ?? "Unknown error")"
            }

        case .export:
            if event.succeeded {
                print("[CloudKitSyncMonitor] CloudKit export completed successfully")
                syncStatus = .synced
                lastSyncDate = Date()
                errorMessage = nil
            } else {
                print("[CloudKitSyncMonitor] CloudKit export failed: \(event.error?.localizedDescription ?? "Unknown error")")
                syncStatus = .error
                errorMessage = "Export failed: \(event.error?.localizedDescription ?? "Unknown error")"
            }

        @unknown default:
            print("[CloudKitSyncMonitor] Unknown CloudKit event type")
        }
    }
    
    func checkCloudKitStatus() {
        let ckContainer = CKContainer(identifier: "iCloud.com.Mingyi.Lumory")

        // First check account status
        ckContainer.accountStatus { [weak self] status, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("[CloudKitSyncMonitor] Account status error: \(error)")
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
        // Test database accessibility by performing a simple query
        let database = container.privateCloudDatabase
        // Use a simple predicate that CloudKit can handle
        let query = CKQuery(recordType: "CD_DiaryEntry", predicate: NSPredicate(value: true))
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
                    print("[CloudKitSyncMonitor] Zone not found (expected for new installations)")
                    self?.syncStatus = .synced
                    self?.errorMessage = nil
                default:
                    print("[CloudKitSyncMonitor] Database access error: \(error)")
                    self?.syncStatus = .error
                    self?.errorMessage = "iCloud sync error: \(error.localizedDescription)"
                }
            } else {
                // Database is accessible
                self?.syncStatus = .synced
                self?.errorMessage = nil
                print("[CloudKitSyncMonitor] CloudKit database accessible, sync ready")
            }
        }
    }

    func forcSync() {
        print("[CloudKitSyncMonitor] Force sync initiated")
        DispatchQueue.main.async { [weak self] in
            self?.syncStatus = .syncing
            self?.errorMessage = nil
        }

        // Trigger Core Data save to push changes to CloudKit
        let context = container.viewContext
        if context.hasChanges {
            do {
                try context.save()
                print("[CloudKitSyncMonitor] Local changes saved, triggering CloudKit sync")
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.syncStatus = .error
                    self?.errorMessage = "Failed to save local changes: \(error.localizedDescription)"
                }
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
        // Use a simple predicate that CloudKit can handle
        let query = CKQuery(recordType: "CD_DiaryEntry", predicate: NSPredicate(value: true))
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
                    print("[CloudKitSyncMonitor] Sync verified (new installation)")
                } else {
                    self?.syncStatus = .error
                    self?.errorMessage = "Sync verification failed: \(error.localizedDescription)"
                    print("[CloudKitSyncMonitor] Sync verification error: \(error)")
                }
            } else {
                self?.syncStatus = .synced
                self?.lastSyncDate = Date()
                self?.errorMessage = nil
                print("[CloudKitSyncMonitor] Sync verified successfully")
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}