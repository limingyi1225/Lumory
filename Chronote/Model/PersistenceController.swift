import CoreData
import CloudKit

extension Notification.Name {
    static let databaseRecreated = Notification.Name("databaseRecreated")
}

final class PersistenceController {
    static let shared = PersistenceController()
    let container: NSPersistentCloudKitContainer
    private var observers: [NSObjectProtocol] = []

    init() {
        // 创建容器，名称必须与 .xcdatamodeld 文件名匹配
        container = NSPersistentCloudKitContainer(name: "Model")
        
        // 配置 iCloud container identifier
        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("无法获取 persistentStoreDescriptions")
        }
        
        // 设置CloudKit配置
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.com.Mingyi.Lumory")
        
        // 启用远程通知
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        
        // 设置URL以确保本地存储位置
        let storeURL = URL.storeURL(for: "Model", databaseName: "Model")
        description.url = storeURL
        
        // Check database health before loading
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let isHealthy = DatabaseRecoveryService.shared.checkDatabaseHealth(at: storeURL)
            if !isHealthy {
                print("[PersistenceController] Database corruption detected before loading!")
                // Synchronously clean up corrupted files before loading
                // Create backup first
                let backupURL = storeURL.appendingPathExtension("corruption-backup-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.copyItem(at: storeURL, to: backupURL)
                print("[PersistenceController] Created backup at: \(backupURL.path)")
                
                // Delete corrupted database files
                try? FileManager.default.removeItem(at: storeURL)
                let walURL = storeURL.deletingPathExtension().appendingPathExtension("sqlite-wal")
                let shmURL = storeURL.deletingPathExtension().appendingPathExtension("sqlite-shm")
                let ckURL = storeURL.deletingPathExtension().appendingPathExtension("sqlite-ck")
                try? FileManager.default.removeItem(at: walURL)
                try? FileManager.default.removeItem(at: shmURL)
                try? FileManager.default.removeItem(at: ckURL)
                print("[PersistenceController] Removed corrupted database files, will recreate on load")
                
                // Continue to loadPersistentStores below - it will create a fresh database
            }
        }
        
        container.loadPersistentStores { [container] storeDescription, error in
            if let error = error as NSError? {
                print("[PersistenceController] Core Data failed to load: \(error), \(error.userInfo)")

                // Check if it's a database corruption error
                if error.domain == NSSQLiteErrorDomain && error.code == 11 {
                    print("[PersistenceController] CRITICAL: Database corruption detected!")
                    
                    // Use the new recovery service
                    DatabaseRecoveryService.shared.performRecovery(for: container) { result in
                        switch result {
                        case .success:
                            print("[PersistenceController] Database recovery completed successfully")
                        case .failure(let recoveryError):
                            print("[PersistenceController] Database recovery failed: \(recoveryError)")
                            fatalError("Cannot recover from database corruption: \(recoveryError)")
                        }
                    }
                    return
                }

                // Check if it's a CloudKit-related error
                if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError,
                   underlyingError.domain == CKErrorDomain {
                    print("[PersistenceController] CloudKit error detected: \(underlyingError)")

                    switch CKError.Code(rawValue: underlyingError.code) {
                    case .notAuthenticated:
                        print("[PersistenceController] User not signed in to iCloud")
                    case .quotaExceeded:
                        print("[PersistenceController] iCloud quota exceeded")
                    case .networkUnavailable:
                        print("[PersistenceController] Network unavailable for CloudKit")
                    case .incompatibleVersion:
                        print("[PersistenceController] CloudKit schema incompatible version")
                    case .badDatabase:
                        print("[PersistenceController] CloudKit database error - may need to reset schema")
                    default:
                        print("[PersistenceController] Other CloudKit error: \(underlyingError.localizedDescription)")
                    }
                }

                // 在开发阶段，可以尝试删除并重新创建存储
                #if DEBUG
                if let url = storeDescription.url {
                    print("[PersistenceController] Attempting to recreate store at: \(url.path)")
                    try? FileManager.default.removeItem(at: url)

                    // Also remove related files
                    let walURL = url.appendingPathExtension("sqlite-wal")
                    let shmURL = url.appendingPathExtension("sqlite-shm")
                    try? FileManager.default.removeItem(at: walURL)
                    try? FileManager.default.removeItem(at: shmURL)

                    // 重新尝试加载
                    container.loadPersistentStores { _, retryError in
                        if let retryError = retryError {
                            print("[PersistenceController] Retry failed: \(retryError)")
                            fatalError("Failed to load Core Data store after retry: \(retryError)")
                        } else {
                            print("[PersistenceController] Store recreated successfully")
                        }
                    }
                }
                #else
                fatalError("Unresolved Core Data error \(error), \(error.userInfo)")
                #endif
            } else {
                print("[PersistenceController] Core Data store loaded successfully")
                if let url = storeDescription.url {
                    print("[PersistenceController] Store location: \(url.path)")
                }
            }
        }
        
        // 配置视图上下文
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        
        // 监听远程变化通知
        let remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] notification in
            print("[PersistenceController] iCloud sync: Remote changes detected")
            
            // Debounce notifications to avoid excessive updates
            self?.container.viewContext.refreshAllObjects()
        }
        observers.append(remoteChangeObserver)

        // 监听导入/导出事件 (iOS 14+ / macOS 11+)
        if #available(iOS 14.0, macOS 11.0, *) {
            let eventObserver = NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: container,
                queue: .main
            ) { notification in
                if let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event {
                    print("[PersistenceController] CloudKit event: \(event.type.rawValue)")

                    switch event.type {
                    case .setup:
                        print("[PersistenceController] CloudKit setup completed")
                    case .import:
                        print("[PersistenceController] CloudKit import: \(event.succeeded ? "succeeded" : "failed")")
                        if let error = event.error {
                            print("[PersistenceController] Import error: \(error)")
                        }
                    case .export:
                        print("[PersistenceController] CloudKit export: \(event.succeeded ? "succeeded" : "failed")")
                        if let error = event.error {
                            print("[PersistenceController] Export error: \(error)")
                        }
                    @unknown default:
                        print("[PersistenceController] Unknown CloudKit event type")
                    }
                }
            }
            observers.append(eventObserver)
        }
        
        // 尝试初始化CloudKit schema
        initializeCloudKitSchema()
        
        // Check CloudKit readiness
        checkCloudKitReadiness()
    }
    
    private func checkCloudKitReadiness() {
        // Verify CloudKit container is properly configured
        let ckContainer = CKContainer(identifier: "iCloud.com.Mingyi.Lumory")
        
        ckContainer.accountStatus { status, error in
            if let error = error {
                print("[PersistenceController] CloudKit account status error: \(error)")
                return
            }
            
            switch status {
            case .available:
                print("[PersistenceController] iCloud account is available")
            case .noAccount:
                print("[PersistenceController] No iCloud account - sync will be disabled")
            case .restricted:
                print("[PersistenceController] iCloud account is restricted")
            case .couldNotDetermine:
                print("[PersistenceController] Could not determine iCloud account status")
            case .temporarilyUnavailable:
                print("[PersistenceController] iCloud temporarily unavailable")
            @unknown default:
                print("[PersistenceController] Unknown iCloud account status")
            }
        }
    }
    
    deinit {
        // Remove all notification observers
        observers.forEach { observer in
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        print("[PersistenceController] deinit - cleaned up observers")
    }
    
    private func handlePreLoadCorruption(storeURL: URL, container: NSPersistentCloudKitContainer) {
        print("[PersistenceController] Handling pre-load corruption...")
        
        // Perform recovery
        DatabaseRecoveryService.shared.performRecovery(for: container) { [weak self] result in
            switch result {
            case .success:
                print("[PersistenceController] Pre-load recovery completed successfully")
                // Reload the container after recovery
                DispatchQueue.main.async {
                    self?.reloadAfterRecovery()
                }
            case .failure(let error):
                print("[PersistenceController] Pre-load recovery failed: \(error)")
                // Try emergency recovery
                self?.performEmergencyRecovery(storeURL: storeURL, container: container)
            }
        }
    }
    
    private func performEmergencyRecovery(storeURL: URL, container: NSPersistentCloudKitContainer) {
        print("[PersistenceController] Performing emergency recovery...")
        
        // Create backup
        let backupURL = storeURL.appendingPathExtension("emergency-backup-\(Date().timeIntervalSince1970)")
        try? FileManager.default.copyItem(at: storeURL, to: backupURL)
        
        // Delete all database files and clear CloudKit tokens
        try? FileManager.default.removeItem(at: storeURL)
        let walURL = storeURL.deletingPathExtension().appendingPathExtension("sqlite-wal")
        let shmURL = storeURL.deletingPathExtension().appendingPathExtension("sqlite-shm")
        let ckURL = storeURL.deletingPathExtension().appendingPathExtension("sqlite-ck")
        try? FileManager.default.removeItem(at: walURL)
        try? FileManager.default.removeItem(at: shmURL)
        try? FileManager.default.removeItem(at: ckURL)
        
        // Clear CloudKit history tokens
        clearCloudKitTokens()
        
        // Try to reload
        container.loadPersistentStores { storeDescription, error in
            if let error = error {
                print("[PersistenceController] Emergency recovery failed: \(error)")
                fatalError("Cannot recover from database corruption")
            } else {
                print("[PersistenceController] Emergency recovery succeeded")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .databaseRecreated, object: nil)
                }
            }
        }
    }
    
    private func reloadAfterRecovery() {
        // This would require reinitializing the entire PersistenceController
        // For now, we'll just post the notification
        NotificationCenter.default.post(name: .databaseRecreated, object: nil)
    }
    
    
    private func initializeCloudKitSchema() {
        #if DEBUG
        // NSPersistentCloudKitContainer automatically manages schema creation
        // Manual initialization is not required in recent versions
        print("[PersistenceController] CloudKit schema is automatically managed by NSPersistentCloudKitContainer")
        
        // Verify the container is properly configured
        if let storeDescription = container.persistentStoreDescriptions.first {
            if let cloudKitOptions = storeDescription.cloudKitContainerOptions {
                print("[PersistenceController] CloudKit container configured: \(cloudKitOptions.containerIdentifier)")
                
                // Check other important settings
                if let historyTracking = storeDescription.options[NSPersistentHistoryTrackingKey] as? NSNumber {
                    print("[PersistenceController] History tracking: \(historyTracking.boolValue ? "Enabled" : "Disabled")")
                }
                
                if let remoteNotifications = storeDescription.options[NSPersistentStoreRemoteChangeNotificationPostOptionKey] as? NSNumber {
                    print("[PersistenceController] Remote notifications: \(remoteNotifications.boolValue ? "Enabled" : "Disabled")")
                }
            } else {
                print("[PersistenceController] WARNING: CloudKit options not configured!")
            }
        }
        #else
        // In production, schema should already be established
        print("[PersistenceController] Using established CloudKit schema in production")
        #endif
    }
    
    /// Clear CloudKit history tokens to resolve token reference errors
    private func clearCloudKitTokens() {
        print("[PersistenceController] Clearing CloudKit history tokens...")
        
        // Clear any stored history tokens in UserDefaults that might be causing issues
        let userDefaults = UserDefaults.standard
        let keys = userDefaults.dictionaryRepresentation().keys
        
        for key in keys {
            if key.contains("NSPersistentHistoryToken") || key.contains("CloudKit") {
                userDefaults.removeObject(forKey: key)
                print("[PersistenceController] Removed token key: \(key)")
            }
        }
        
        // Also try to clear any persistent history
        do {
            let request = NSPersistentHistoryChangeRequest.deleteHistory(before: Date())
            try container.viewContext.execute(request)
            try container.viewContext.save()
            print("[PersistenceController] Cleared persistent history")
        } catch {
            print("[PersistenceController] Failed to clear persistent history: \(error)")
        }
    }
}

extension URL {
    static func storeURL(for appGroup: String, databaseName: String) -> URL {
        // Try to use iCloud container first
        if let iCloudContainer = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
            let documentsURL = iCloudContainer.appendingPathComponent("Documents")

            // Ensure the Documents directory exists
            do {
                try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true, attributes: nil)
                let storeURL = documentsURL.appendingPathComponent("\(databaseName).sqlite")
                print("[PersistenceController] Using iCloud store URL: \(storeURL.path)")
                return storeURL
            } catch {
                print("[PersistenceController] Failed to create iCloud Documents directory: \(error)")
            }
        }

        // Fallback to local Documents directory
        let localDocuments = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let storeURL = localDocuments.appendingPathComponent("\(databaseName).sqlite")
        print("[PersistenceController] Using local store URL: \(storeURL.path)")
        return storeURL
    }

    /// Check if iCloud is available and accessible
    static func isICloudAvailable() -> Bool {
        guard let iCloudContainer = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") else {
            return false
        }

        // Test if we can write to the iCloud container
        let testFile = iCloudContainer.appendingPathComponent("test_access.tmp")
        do {
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: testFile)
            return true
        } catch {
            print("[PersistenceController] iCloud container not accessible: \(error)")
            return false
        }
    }
}

// MARK: - CloudKit Debugging
extension PersistenceController {
    
    /// Debug method to check and fix CloudKit issues
    func debugCloudKitIssues() {
        print("[PersistenceController] Starting CloudKit debug...")
        
        // Check if we're using the correct container identifier
        let expectedIdentifier = "iCloud.com.Mingyi.Lumory"
        print("[PersistenceController] Expected CloudKit container: \(expectedIdentifier)")
        
        // Get current store description
        if let storeDescription = container.persistentStoreDescriptions.first {
            if let cloudKitOptions = storeDescription.cloudKitContainerOptions {
                print("[PersistenceController] Current CloudKit container: \(cloudKitOptions.containerIdentifier)")
            } else {
                print("[PersistenceController] WARNING: No CloudKit options configured!")
            }
            
            // Check if history tracking is enabled
            if let historyTracking = storeDescription.options[NSPersistentHistoryTrackingKey] as? NSNumber {
                print("[PersistenceController] History tracking enabled: \(historyTracking.boolValue)")
            }
            
            // Check if remote change notifications are enabled
            if let remoteNotifications = storeDescription.options[NSPersistentStoreRemoteChangeNotificationPostOptionKey] as? NSNumber {
                print("[PersistenceController] Remote notifications enabled: \(remoteNotifications.boolValue)")
            }
        }
        
        // Try to reset the schema if needed
        #if DEBUG
        SyncDiagnosticService.resetCloudKitSchema(container: container)
        #endif
        
        // Additional debugging for recordname issues
        debugRecordNameIssue()
    }
    
    /// Specific debugging for "recordname" field issues
    private func debugRecordNameIssue() {
        print("[PersistenceController] Debugging 'recordname' field issue...")
        
        // The "recordname" error typically occurs when:
        // 1. CloudKit schema is out of sync
        // 2. The app is trying to query before schema is ready
        // 3. There's a mismatch between Core Data model and CloudKit schema
        
        print("[PersistenceController] Possible solutions:")
        print("[PersistenceController] 1. Delete the app and reinstall")
        print("[PersistenceController] 2. In CloudKit Dashboard, delete the schema and let it recreate")
        print("[PersistenceController] 3. Ensure Core Data model has 'Used with CloudKit' enabled")
        print("[PersistenceController] 4. Check that all Core Data attributes are CloudKit compatible")
        
        // Check Core Data model configuration
        let model = container.managedObjectModel
        if let diaryEntity = model.entitiesByName["DiaryEntry"] {
            print("[PersistenceController] DiaryEntry entity found")
            print("[PersistenceController] Attributes:")
            for (name, property) in diaryEntity.attributesByName {
                print("[PersistenceController]   - \(name): \(property.attributeType.rawValue)")
            }
        } else {
            print("[PersistenceController] WARNING: DiaryEntry entity not found in model!")
        }
    }
}

// MARK: - Cleanup
extension PersistenceController {
    // Public method to save context with error handling
    func save() {
        let context = container.viewContext
        
        guard context.hasChanges else { return }
        
        do {
            try context.save()
        } catch {
            let nsError = error as NSError
            print("[PersistenceController] Save error: \(nsError), \(nsError.userInfo)")
        }
    }
    
    // Batch delete with performance optimization - uses background context for thread safety
    func batchDelete<T: NSManagedObject>(_ type: T.Type, predicate: NSPredicate? = nil) async throws {
        try await container.performBackgroundTask { context in
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: String(describing: type))
            fetchRequest.predicate = predicate

            let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            batchDeleteRequest.resultType = .resultTypeObjectIDs

            let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
            let objectIDArray = result?.result as? [NSManagedObjectID] ?? []
            let changes = [NSDeletedObjectsKey: objectIDArray]

            // Merge changes to view context on main thread (use async to avoid blocking)
            // Capture viewContext reference before async to satisfy Sendable requirements
            let viewContext = self.container.viewContext
            DispatchQueue.main.async {
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [viewContext])
            }
        }
    }

    // Synchronous version for backwards compatibility (deprecated)
    @available(*, deprecated, message: "Use async version instead")
    func batchDeleteSync<T: NSManagedObject>(_ type: T.Type, predicate: NSPredicate? = nil) throws {
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: String(describing: type))
        fetchRequest.predicate = predicate

        let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        batchDeleteRequest.resultType = .resultTypeObjectIDs

        // Use background context to avoid blocking main thread
        var deleteError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        container.performBackgroundTask { context in
            do {
                let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
                let objectIDArray = result?.result as? [NSManagedObjectID] ?? []
                let changes = [NSDeletedObjectsKey: objectIDArray]

                DispatchQueue.main.async {
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [self.container.viewContext])
                }
            } catch {
                deleteError = error
            }
            semaphore.signal()
        }

        semaphore.wait()
        if let error = deleteError {
            throw error
        }
    }
}