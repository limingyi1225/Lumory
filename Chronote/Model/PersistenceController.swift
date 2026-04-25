import CoreData
import CloudKit

extension Notification.Name {
    static let databaseRecreated = Notification.Name("databaseRecreated")
    static let persistentStoreLoadFailed = Notification.Name("persistentStoreLoadFailed")
}

final class PersistenceController {
    /// `.shared` 在普通启动下指向真实 CloudKit-backed store；
    /// 检测到 `-LumoryUITestSampleData YES` launchArg 时自动切换到 **in-memory store**，
    /// 完全旁路 CloudKit、本地 SQLite、用户数据 —— 这是 reviewer 第二轮提出的硬性要求：
    /// "screenshot/CI 模式必须真在内存里跑，不能复用真实 store + 启发式判断安全"。
    /// 注意：launchArg 的解析在第一次访问 `.shared` 时同步执行（早于 `App.init` 中所有
    /// 其他属性初始化），所以 `seedIfNeeded` 进来时 store 类型已确定。
    static let shared: PersistenceController = {
        let args = ProcessInfo.processInfo.arguments
        var screenshotMode = false
        if let idx = args.firstIndex(of: "-LumoryUITestSampleData"),
           idx + 1 < args.count,
           args[idx + 1].uppercased() == "YES" {
            screenshotMode = true
        }
        return PersistenceController(inMemory: screenshotMode)
    }()

    let container: NSPersistentCloudKitContainer
    let isInMemory: Bool
    private var observers: [NSObjectProtocol] = []

    /// 标识这次启动是否处在"加载失败、等用户决策"的降级态。
    /// 上层需要时自己去读；暂时不走 `@Published` / ObservableObject，因为真机启动时
    /// 把 PersistenceController 放进 `@StateObject` 会触发空白首屏（疑似 iOS 26 生命周期 quirk）。
    private(set) var isStoreLoadFailed = false
    /// 上次加载失败的 error（给 UI 展示用）。
    private(set) var storeLoadError: NSError?

    /// 默认 init 走真实 CloudKit-backed store；`inMemory: true` 走 NSInMemoryStoreType。
    /// in-memory 模式下完全不挂 CloudKit container options、不持久化、不走 history tracking。
    init(inMemory: Bool = false) {
        self.isInMemory = inMemory
        // 创建容器，名称必须与 .xcdatamodeld 文件名匹配
        container = NSPersistentCloudKitContainer(name: "Model")

        // 配置 iCloud container identifier
        guard let description = container.persistentStoreDescriptions.first else {
            // 这是构建期配置错误（xcdatamodeld 没编译进包），不是用户数据问题，留 fatalError。
            fatalError("无法获取 persistentStoreDescriptions — xcdatamodeld 未正确打包")
        }

        if inMemory {
            // 完全旁路：不挂 CloudKit options，store 类型置为 in-memory，URL 置 /dev/null。
            // 这样 batch delete + insert 完全发生在 RAM 里，不写盘、不同步到 CloudKit、不污染
            // 用户的真实日记。Screenshot run 结束、进程退出，数据自动消失。
            description.type = NSInMemoryStoreType
            description.url = URL(fileURLWithPath: "/dev/null")
            description.cloudKitContainerOptions = nil
            description.shouldMigrateStoreAutomatically = false
            description.shouldInferMappingModelAutomatically = false
            Log.info("[PersistenceController] Initialized with IN-MEMORY store (screenshot/CI mode)", category: .persistence)
        } else {
            // 设置CloudKit配置
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.com.Mingyi.Lumory")

            // 启用远程通知
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

            // **显式**打开 lightweight migration。NSPersistentCloudKitContainer 在部分 iOS 版本下
            // 默认行为不稳定，显式设置这两个 option 保证模型新加可选字段（embedding/themes/wordCount）
            // 升级时能自动完成 schema 迁移，而不是抛 "incompatible model" 把用户挡在门外。
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true

            // 设置URL以确保本地存储位置
            let storeURL = URL.storeURL(for: "Model", databaseName: "Model")
            description.url = storeURL
        }

        // NOTE：以前这里有一段 pre-load `integrity_check` + 静默删除数据库文件的代码——
        // SQLite `PRAGMA integrity_check` 在 WAL 锁竞争 / 第三方备份软件持有 fd 时会假报故障，
        // 然后我们就会在**用户未确认**的情况下把本地日记抹掉。永远不要在未经用户同意时删本地数据。
        // 真正的损坏走 `loadPersistentStores` 的 error 分支（走 DatabaseRecoveryService，有 UI 弹窗确认）。

        container.loadPersistentStores { [weak self, container] storeDescription, error in
            if let error = error as NSError? {
                Log.error("[PersistenceController] Core Data failed to load: \(error), \(error.userInfo)", category: .persistence)

                // Log additional diagnostic info for CloudKit errors
                if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError,
                   underlyingError.domain == CKErrorDomain {
                    Log.error("[PersistenceController] CloudKit underlying error: \(underlyingError)", category: .persistence)
                }

                // Database corruption (SQLITE_CORRUPT = 11) → 走 recovery，recovery 内部会弹窗确认。
                if error.domain == NSSQLiteErrorDomain && error.code == 11 {
                    Log.info(
                        "[PersistenceController] Database corruption detected — requesting user confirmation before recovery",
                        category: .persistence
                    )

                    DatabaseRecoveryService.shared.performRecovery(for: container) { [weak self] result in
                        switch result {
                        case .success:
                            Log.info("[PersistenceController] Database recovery completed successfully", category: .persistence)
                            DispatchQueue.main.async {
                                self?.isStoreLoadFailed = false
                                self?.storeLoadError = nil
                            }
                        case .failure(let recoveryError):
                            // **不再 fatalError**：恢复失败也让 app 继续运行在降级态，
                            // 这样用户至少能看到 Settings 里的手动操作入口，也能导出 iCloud 数据。
                            Log.error("[PersistenceController] Database recovery failed: \(recoveryError) — entering degraded mode", category: .persistence)
                            DispatchQueue.main.async {
                                self?.isStoreLoadFailed = true
                                self?.storeLoadError = error
                                self?.postStoreLoadFailure(error)
                            }
                        }
                    }
                    return
                }

                // 其他错误（常见：CloudKit 不可用 / 迁移失败 / 权限问题）都进降级态。
                // release 和 debug 都不 fatalError——静默 crash 让用户重启无数次比降级 UI 更糟。
                DispatchQueue.main.async {
                    self?.isStoreLoadFailed = true
                    self?.storeLoadError = error
                    self?.postStoreLoadFailure(error)
                }
            } else {
                Log.info("[PersistenceController] Core Data store loaded successfully", category: .persistence)
                if let url = storeDescription.url {
                    Log.info("[PersistenceController] Store location: \(url.path)", category: .persistence)
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
        ) { _ in
            Log.info("[PersistenceController] iCloud sync: Remote changes detected", category: .persistence)
            // automaticallyMergesChangesFromParent already merges CloudKit changes.
            // A blanket refreshAllObjects() here would discard unsaved edits in viewContext.
        }
        observers.append(remoteChangeObserver)

        // 监听导入/导出事件 (iOS 14+ / macOS 11+)
        if #available(iOS 14.0, macOS 11.0, *) {
            let eventObserver = NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: container,
                queue: .main
            ) { notification in
                if let event = notification.userInfo?[
                    NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                ] as? NSPersistentCloudKitContainer.Event {
                    Log.info("[PersistenceController] CloudKit event: \(event.type.rawValue)", category: .persistence)

                    switch event.type {
                    case .setup:
                        Log.info("[PersistenceController] CloudKit setup completed", category: .persistence)
                    case .import:
                        Log.error("[PersistenceController] CloudKit import: \(event.succeeded ? "succeeded" : "failed")", category: .persistence)
                        if let error = event.error {
                            Log.error("[PersistenceController] Import error: \(error)", category: .persistence)
                        }
                    case .export:
                        Log.error("[PersistenceController] CloudKit export: \(event.succeeded ? "succeeded" : "failed")", category: .persistence)
                        if let error = event.error {
                            Log.error("[PersistenceController] Export error: \(error)", category: .persistence)
                        }
                    @unknown default:
                        Log.info("[PersistenceController] Unknown CloudKit event type", category: .persistence)
                    }
                }
            }
            observers.append(eventObserver)
        }
        
        // 尝试初始化CloudKit schema
        initializeCloudKitSchema()
    }

    private func postStoreLoadFailure(_ error: NSError) {
        NotificationCenter.default.post(
            name: .persistentStoreLoadFailed,
            object: self,
            userInfo: ["error": error]
        )
    }
    
    deinit {
        // Remove all notification observers
        observers.forEach { observer in
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        Log.info("[PersistenceController] deinit - cleaned up observers", category: .persistence)
    }
    
    private func initializeCloudKitSchema() {
        #if DEBUG
        // NSPersistentCloudKitContainer automatically manages schema creation
        // Manual initialization is not required in recent versions
        Log.info("[PersistenceController] CloudKit schema is automatically managed by NSPersistentCloudKitContainer", category: .persistence)
        
        // Verify the container is properly configured
        if let storeDescription = container.persistentStoreDescriptions.first {
            if let cloudKitOptions = storeDescription.cloudKitContainerOptions {
                Log.info("[PersistenceController] CloudKit container configured: \(cloudKitOptions.containerIdentifier)", category: .persistence)
                
                // Check other important settings
                if let historyTracking = storeDescription.options[NSPersistentHistoryTrackingKey] as? NSNumber {
                    Log.info("[PersistenceController] History tracking: \(historyTracking.boolValue ? "Enabled" : "Disabled")", category: .persistence)
                }
                
                if let remoteNotifications = storeDescription.options[NSPersistentStoreRemoteChangeNotificationPostOptionKey] as? NSNumber {
                    Log.info("[PersistenceController] Remote notifications: \(remoteNotifications.boolValue ? "Enabled" : "Disabled")", category: .persistence)
                }
            } else {
                Log.warning("[PersistenceController] WARNING: CloudKit options not configured!", category: .persistence)
            }
        }
        #else
        // In production, schema should already be established
        Log.info("[PersistenceController] Using established CloudKit schema in production", category: .persistence)
        #endif
    }
}

extension URL {
    /// SQLite store 位置。**必须是本地 Application Support**，不能放 iCloud ubiquity container。
    ///
    /// 之前的实现把 `.sqlite` 放到 `iCloud.com.Mingyi.Lumory/Documents/Model.sqlite`——
    /// 同时 `NSPersistentCloudKitContainer` 又在用 CloudKit 私有数据库做同步。**两套系统在操作同一文件**，
    /// iCloud Drive 会在 WAL checkpoint 窗口做文件替换 / truncate，随机静默丢数据。
    /// Apple 明确要求：NSPersistentCloudKitContainer 的 store 必须 local，CloudKit 用自己的 sync 机制。
    ///
    /// 老用户升级时走 `migrateFromUbiquityIfNeeded` 一次性把老数据搬到新位置，然后把老文件
    /// 改名 `.legacy-ubiquity` 保留（不直接删，万一搬迁中断还能人工恢复）。
    static func storeURL(for appGroup: String, databaseName: String) -> URL {
        // `urls(for:in:)` 在 iOS 进程里实际不会返回空，但 SwiftLint 不知情；
        // 用 fallback 到 tmpDir 兜底，并打 error log 让我们能在 Crashlytics 上发现这种"不可能"的状况。
        let localSupport: URL
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            localSupport = dir
        } else {
            localSupport = FileManager.default.temporaryDirectory
            Log.error("[PersistenceController] applicationSupportDirectory unavailable, falling back to: \(localSupport.path)", category: .persistence)
        }
        // Application Support 在 simulator 首次启动时可能不存在，确保一下。
        try? FileManager.default.createDirectory(at: localSupport, withIntermediateDirectories: true)
        let storeURL = localSupport.appendingPathComponent("\(databaseName).sqlite")

        // 老用户可能有两种存位置：
        //   1. iCloud ubiquity container/Documents/Model.sqlite（开过 iCloud 的）
        //   2. 本地 Documents/Model.sqlite（没开 iCloud 的 fallback 分支）
        // 都要迁，否则升级后看不到历史日记。
        migrateFromLegacyLocationsIfNeeded(targetURL: storeURL, databaseName: databaseName)

        Log.info("[PersistenceController] Using local store URL: \(storeURL.path)", category: .persistence)
        return storeURL
    }

    /// 一次性把老用户的 `.sqlite` 搬到新的 Application Support 位置。
    /// 覆盖两条老路径：ubiquity container（开 iCloud 的用户）和本地 Documents（没开 iCloud 的）。
    /// 先搬 ubiquity（因为它通常是更完整的），没有才 fallback 到本地 Documents。
    private static func migrateFromLegacyLocationsIfNeeded(targetURL: URL, databaseName: String) {
        let fm = FileManager.default
        // 本地新位置已有 store 就不搬——走过一次就不再触发
        guard !fm.fileExists(atPath: targetURL.path) else { return }

        // 优先尝试 ubiquity（老版本有 iCloud 时优先写到那）
        if let ubiquityContainer = fm.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
            let ubiquityDocs = ubiquityContainer.appendingPathComponent("Documents")
            let legacyStoreURL = ubiquityDocs.appendingPathComponent("\(databaseName).sqlite")
            if fm.fileExists(atPath: legacyStoreURL.path) {
                migrateFromLegacyDirectory(
                    sourceDir: ubiquityDocs,
                    targetURL: targetURL,
                    databaseName: databaseName,
                    label: "ubiquity",
                    archive: true
                )
                // 搬完就返回，不再看本地 Documents（老数据以 ubiquity 的为准）
                if fm.fileExists(atPath: targetURL.path) { return }
            }
        }

        // 回退路径：本地 Documents（老版本无 iCloud 时的 fallback）
        guard let localDocs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            Log.error("[PersistenceController] documentDirectory unavailable, skipping legacy local migration", category: .persistence)
            return
        }
        let legacyLocalStore = localDocs.appendingPathComponent("\(databaseName).sqlite")
        if fm.fileExists(atPath: legacyLocalStore.path) {
            migrateFromLegacyDirectory(
                sourceDir: localDocs,
                targetURL: targetURL,
                databaseName: databaseName,
                label: "local-documents",
                archive: true
            )
        }
    }

    /// 从指定源目录拷 .sqlite + -wal/-shm/-ck 四件套到目标位置。
    /// `archive=true` 时把源文件改名 `.legacy-<label>` 保留一份，失败可人工恢复。
    private static func migrateFromLegacyDirectory(sourceDir: URL, targetURL: URL, databaseName: String, label: String, archive: Bool) {
        let fm = FileManager.default
        let legacyStoreURL = sourceDir.appendingPathComponent("\(databaseName).sqlite")
        guard fm.fileExists(atPath: legacyStoreURL.path) else { return }

        Log.info("[PersistenceController] 检测到 \(label) 里的老 store，开始迁移", category: .persistence)

        // SQLite 的三个兄弟文件都要搬：主库 + WAL + SHM。缺任一个都可能丢未提交事务。
        let siblings = ["sqlite", "sqlite-wal", "sqlite-shm", "sqlite-ck"]
        var migratedAll = true
        for ext in siblings {
            let src = sourceDir.appendingPathComponent("\(databaseName).\(ext)")
            let dst = targetURL.deletingPathExtension().appendingPathExtension(ext)
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                try fm.copyItem(at: src, to: dst)
                Log.info("[PersistenceController] 已复制 \(ext)", category: .persistence)
            } catch {
                Log.error("[PersistenceController] 复制 \(ext) 失败：\(error)", category: .persistence)
                migratedAll = false
            }
        }

        // 只有全部复制成功才把老文件改名归档；有失败就保留原位，等下次启动再试一次
        if migratedAll {
            if archive {
                for ext in siblings {
                    let src = sourceDir.appendingPathComponent("\(databaseName).\(ext)")
                    let archived = sourceDir.appendingPathComponent("\(databaseName).\(ext).legacy-\(label)")
                    guard fm.fileExists(atPath: src.path) else { continue }
                    do {
                        // 已经有归档副本就先删掉（防止多次搬迁冲突）
                        try? fm.removeItem(at: archived)
                        try fm.moveItem(at: src, to: archived)
                    } catch {
                        Log.error("[PersistenceController] 归档 \(ext) 失败：\(error)", category: .persistence)
                    }
                }
            }
            Log.info("[PersistenceController] \(label) → Application Support 迁移完成", category: .persistence)
        } else {
            // 清掉部分已复制的目标文件，不让 Core Data 打开半路状态
            for ext in siblings {
                let dst = targetURL.deletingPathExtension().appendingPathExtension(ext)
                try? fm.removeItem(at: dst)
            }
            Log.error("[PersistenceController] 迁移部分失败，保留 \(label) 原位，下次启动重试", category: .persistence)
        }
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
            Log.error("[PersistenceController] iCloud container not accessible: \(error)", category: .persistence)
            return false
        }
    }
}

// MARK: - CloudKit Debugging
extension PersistenceController {
    /// Debug method to check and fix CloudKit issues
    func debugCloudKitIssues() {
        Log.info("[PersistenceController] Starting CloudKit debug...", category: .persistence)
        
        // Check if we're using the correct container identifier
        let expectedIdentifier = "iCloud.com.Mingyi.Lumory"
        Log.info("[PersistenceController] Expected CloudKit container: \(expectedIdentifier)", category: .persistence)
        
        // Get current store description
        if let storeDescription = container.persistentStoreDescriptions.first {
            if let cloudKitOptions = storeDescription.cloudKitContainerOptions {
                Log.info("[PersistenceController] Current CloudKit container: \(cloudKitOptions.containerIdentifier)", category: .persistence)
            } else {
                Log.warning("[PersistenceController] WARNING: No CloudKit options configured!", category: .persistence)
            }
            
            // Check if history tracking is enabled
            if let historyTracking = storeDescription.options[NSPersistentHistoryTrackingKey] as? NSNumber {
                Log.info("[PersistenceController] History tracking enabled: \(historyTracking.boolValue)", category: .persistence)
            }
            
            // Check if remote change notifications are enabled
            if let remoteNotifications = storeDescription.options[NSPersistentStoreRemoteChangeNotificationPostOptionKey] as? NSNumber {
                Log.info("[PersistenceController] Remote notifications enabled: \(remoteNotifications.boolValue)", category: .persistence)
            }
        }
        
        // Try to reset the schema if needed
        #if DEBUG
        SyncDiagnosticService.logCloudKitSchemaHints(container: container)
        #endif
        
        // Additional debugging for recordname issues
        debugRecordNameIssue()
    }
    
    /// Specific debugging for "recordname" field issues
    private func debugRecordNameIssue() {
        Log.info("[PersistenceController] Debugging 'recordname' field issue...", category: .persistence)
        
        // The "recordname" error typically occurs when:
        // 1. CloudKit schema is out of sync
        // 2. The app is trying to query before schema is ready
        // 3. There's a mismatch between Core Data model and CloudKit schema
        
        Log.info("[PersistenceController] Possible solutions:", category: .persistence)
        Log.info("[PersistenceController] 1. Delete the app and reinstall", category: .persistence)
        Log.info("[PersistenceController] 2. In CloudKit Dashboard, delete the schema and let it recreate", category: .persistence)
        Log.info("[PersistenceController] 3. Ensure Core Data model has 'Used with CloudKit' enabled", category: .persistence)
        Log.info("[PersistenceController] 4. Check that all Core Data attributes are CloudKit compatible", category: .persistence)
        
        // Check Core Data model configuration
        let model = container.managedObjectModel
        if let diaryEntity = model.entitiesByName["DiaryEntry"] {
            Log.info("[PersistenceController] DiaryEntry entity found", category: .persistence)
            Log.info("[PersistenceController] Attributes:", category: .persistence)
            for (name, property) in diaryEntity.attributesByName {
                Log.info("[PersistenceController]   - \(name): \(property.attributeType.rawValue)", category: .persistence)
            }
        } else {
            Log.warning("[PersistenceController] WARNING: DiaryEntry entity not found in model!", category: .persistence)
        }
    }
}

// MARK: - Cleanup
extension PersistenceController {
    // Batch delete with performance optimization - uses background context for thread safety
    func batchDelete<T: NSManagedObject>(_ type: T.Type, predicate: NSPredicate? = nil) async throws {
        let objectIDArray: [NSManagedObjectID] = try await container.performBackgroundTask { context in
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: String(describing: type))
            fetchRequest.predicate = predicate

            let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            batchDeleteRequest.resultType = .resultTypeObjectIDs

            let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
            return result?.result as? [NSManagedObjectID] ?? []
        }

        await MainActor.run {
            let changes = [NSDeletedObjectsKey: objectIDArray]
            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [container.viewContext])
        }
    }
}
