import Foundation
import CoreData
import CloudKit

/// **`@MainActor` 全类标注**:此类的 `@Published` `syncStatus` / `errorMessage` 通过 SwiftUI
/// `@EnvironmentObject` 在多个 view 上观察。CK API 的 closure 在后台 queue 触发,需要写入这些
/// 属性 → 必须 hop 到主线程。之前靠每个 closure 内 `DispatchQueue.main.async` wrap 兜底(项目里
/// 命中 6 处),容易漏一处就出 SwiftUI "Publishing changes from background threads" 警告。
/// 整类标 `@MainActor` 后:
///   - 所有 method body 默认 main isolated,内部 @Published 写入直接合法
///   - CK closure(background queue)调本类 method 必须显式 `Task { @MainActor in ... }` —
///     编译器逼着写,漏不了
@available(iOS 13.0, macOS 10.15, *)
@MainActor
class CloudKitSyncMonitor: ObservableObject {
    @Published var syncStatus: SyncStatus = .unknown
    @Published var errorMessage: String?
    
    private let container: NSPersistentCloudKitContainer

    /// Block-form `addObserver` returns opaque NSObjectProtocol tokens; `removeObserver(self)`
    /// only handles target/selector registrations and would leak these forever.
    /// Track every block observer here so `deinit` can release them explicitly.
    private var observerTokens: [NSObjectProtocol] = []

    /// `.active` 的机会式刷新太频繁——折叠通知中心、应用切换都会触发，每次都打 CloudKit
    /// 浪费配额。给 `checkCloudKitStatus()` 加 30s 冷却,显式刷新（`forceSync()`）走另一条路
    /// 直接绕过冷却。
    private var lastCheckDate: Date?

    #if DEBUG
    private static var isRunningHostedUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    #endif

    enum SyncStatus: String {
        case unknown = "Unknown"
        case syncing = "Syncing"
        case synced = "Synced"
        case error = "Error"
        case notSignedIn = "Not Signed In"
        case networkUnavailable = "Network Unavailable"
    }
    
    init(container: NSPersistentCloudKitContainer) {
        self.container = container
        setupNotifications()
        checkCloudKitStatus()
    }
    
    private func setupNotifications() {
        // 监听远程变化。
        // **`queue: .main`** 保证 closure 在主线程跑,**但 Swift 6 不知道**(closure 类型是 nonisolated)。
        // 用 `MainActor.assumeIsolated` 断言运行时确实在 main(在 main 上一定真) → 编译器允许直接
        // 写 @Published / 调 main-isolated method,无需 Task hop。zero overhead,iOS 17+ 可用。
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            Log.info("[CloudKitSyncMonitor] Remote changes detected", category: .sync)
            MainActor.assumeIsolated {
                self?.syncStatus = .syncing
                self?.errorMessage = nil
            }
        })

        // 监听Core Data保存通知
        observerTokens.append(NotificationCenter.default.addObserver(
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
            MainActor.assumeIsolated {
                self?.syncStatus = .syncing
                self?.errorMessage = nil
            }
        })

        // 监听CloudKit容器事件 (iOS 14+ / macOS 11+)
        if #available(iOS 14.0, macOS 11.0, *) {
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: container,
                queue: .main
            ) { [weak self] notification in
                let eventKey = NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                if let event = notification.userInfo?[eventKey] as? NSPersistentCloudKitContainer.Event {
                    MainActor.assumeIsolated {
                        self?.handleCloudKitEvent(event)
                    }
                }
            })
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
                let detail = event.error?.localizedDescription ?? NSLocalizedString(
                    "sync.error.unknownDetail",
                    value: "未知错误",
                    comment: "Fallback when CloudKit event has no description"
                )
                Log.error("[CloudKitSyncMonitor] CloudKit setup failed: \(detail)", category: .sync)
                syncStatus = .error
                let template = NSLocalizedString(
                    "sync.error.setupFailed",
                    value: "CloudKit 初始化失败：%@",
                    comment: "Shown when CloudKit setup event fails; %@ is system error"
                )
                errorMessage = String(format: template, detail)
            }

        case .import:
            if event.succeeded {
                Log.info("[CloudKitSyncMonitor] CloudKit import completed successfully", category: .sync)
                syncStatus = .synced
                errorMessage = nil
            } else {
                let detail = event.error?.localizedDescription ?? NSLocalizedString(
                    "sync.error.unknownDetail",
                    value: "未知错误",
                    comment: "Fallback when CloudKit event has no description"
                )
                Log.error("[CloudKitSyncMonitor] CloudKit import failed: \(detail)", category: .sync)
                syncStatus = .error
                let template = NSLocalizedString(
                    "sync.error.importFailed",
                    value: "导入失败：%@",
                    comment: "Shown when CloudKit import event fails; %@ is system error"
                )
                errorMessage = String(format: template, detail)
            }

        case .export:
            if event.succeeded {
                Log.info("[CloudKitSyncMonitor] CloudKit export completed successfully", category: .sync)
                syncStatus = .synced
                errorMessage = nil
            } else {
                let detail = event.error?.localizedDescription ?? NSLocalizedString(
                    "sync.error.unknownDetail",
                    value: "未知错误",
                    comment: "Fallback when CloudKit event has no description"
                )
                Log.error("[CloudKitSyncMonitor] CloudKit export failed: \(detail)", category: .sync)
                syncStatus = .error
                let template = NSLocalizedString(
                    "sync.error.exportFailed",
                    value: "导出失败：%@",
                    comment: "Shown when CloudKit export event fails; %@ is system error"
                )
                errorMessage = String(format: template, detail)
            }

        @unknown default:
            Log.info("[CloudKitSyncMonitor] Unknown CloudKit event type", category: .sync)
        }
    }
    
    func checkCloudKitStatus() {
        #if DEBUG
        guard !Self.isRunningHostedUnitTests else {
            syncStatus = .unknown
            errorMessage = nil
            return
        }
        #endif

        // 30s 冷却：scenePhase=.active 每次都触发，频繁切换前后台不应反复打 CloudKit。
        // `forceSync()` 用户主动刷新走 `checkCloudKitStatusAndWaitForSync()` 直接绕过本节流。
        if let last = lastCheckDate, Date().timeIntervalSince(last) < 30 {
            Log.info("[CloudKitSyncMonitor] checkCloudKitStatus skipped (cooldown)", category: .sync)
            return
        }
        lastCheckDate = Date()

        let ckContainer = CKContainer(identifier: "iCloud.com.Mingyi.Lumory")

        // First check account status
        ckContainer.accountStatus { [weak self] status, error in
            Task { @MainActor [weak self] in
                if let error = error {
                    Log.error("[CloudKitSyncMonitor] Account status error: \(error)", category: .sync)
                    self?.syncStatus = .error
                    let template = NSLocalizedString(
                        "sync.error.accountError",
                        value: "iCloud 账户错误：%@",
                        comment: "iCloud account-status error; %@ is system message"
                    )
                    self?.errorMessage = String(format: template, error.localizedDescription)
                    return
                }

                switch status {
                case .available:
                    // Account is available, now check database accessibility
                    self?.checkDatabaseAccessibility(container: ckContainer)
                case .noAccount:
                    self?.syncStatus = .notSignedIn
                    self?.errorMessage = NSLocalizedString(
                        "sync.error.noAccount",
                        value: "请前往系统设置登录 iCloud",
                        comment: "Error shown when user has no iCloud account"
                    )
                case .restricted:
                    self?.syncStatus = .notSignedIn
                    self?.errorMessage = NSLocalizedString(
                        "sync.error.restricted",
                        value: "iCloud 访问受限",
                        comment: "Error shown when iCloud access is restricted (e.g. Screen Time)"
                    )
                case .couldNotDetermine:
                    self?.syncStatus = .unknown
                    self?.errorMessage = NSLocalizedString(
                        "sync.error.couldNotDetermine",
                        value: "无法确定 iCloud 状态",
                        comment: "Error shown when iCloud account status is indeterminate"
                    )
                case .temporarilyUnavailable:
                    self?.syncStatus = .networkUnavailable
                    self?.errorMessage = NSLocalizedString(
                        "sync.error.temporarilyUnavailable",
                        value: "iCloud 暂时不可用",
                        comment: "Error shown when iCloud is temporarily unavailable"
                    )
                @unknown default:
                    self?.syncStatus = .unknown
                    self?.errorMessage = NSLocalizedString(
                        "sync.error.unknown",
                        value: "未知的 iCloud 状态",
                        comment: "Fallback error for unknown iCloud account status"
                    )
                }
            }
        }
    }

    private func checkDatabaseAccessibility(container: CKContainer) {
        // Test database accessibility without querying record fields. CKQuery predicates/sorts
        // require schema query indexes in production, including system fields like ___modTime.
        let database = container.privateCloudDatabase

        // CloudKit `database.fetch/perform` callback 在 CK 后台队列触发,**不在主线程**,
        // 所以这里不能用 `MainActor.assumeIsolated`(会断言失败崩溃)。
        // `handleDatabaseAccessibilityResult` 本身是 main isolated → 用 `Task { @MainActor in ... }` hop。
        database.fetchAllRecordZones { [weak self] _, error in
            Task { @MainActor [weak self] in
                self?.handleDatabaseAccessibilityResult(error: error)
            }
        }
    }

    private func handleDatabaseAccessibilityResult(error: Error?) {
        if let error = error {
            let ckError = error as? CKError
            switch ckError?.code {
            case .networkUnavailable, .networkFailure:
                syncStatus = .networkUnavailable
                errorMessage = NSLocalizedString(
                    "sync.error.networkUnavailable",
                    value: "iCloud 同步无法连接网络",
                    comment: "Shown when CloudKit DB access fails due to network"
                )
            case .notAuthenticated:
                syncStatus = .notSignedIn
                errorMessage = NSLocalizedString(
                    "sync.error.notAuthenticated",
                    value: "请登录 iCloud",
                    comment: "Shown when CloudKit DB access fails due to missing auth"
                )
            case .quotaExceeded:
                syncStatus = .error
                errorMessage = NSLocalizedString(
                    "sync.error.quotaExceeded",
                    value: "iCloud 存储空间不足",
                    comment: "Shown when CloudKit returns quota exceeded"
                )
            case .zoneNotFound, .userDeletedZone:
                // This is expected for new installations
                Log.info("[CloudKitSyncMonitor] Zone not found (expected for new installations)", category: .sync)
                syncStatus = .synced
                errorMessage = nil
            default:
                Log.error("[CloudKitSyncMonitor] Database access error: \(error)", category: .sync)
                syncStatus = .error
                let template = NSLocalizedString(
                    "sync.error.generic",
                    value: "iCloud 同步错误：%@",
                    comment: "Generic CloudKit DB error; %@ is system message"
                )
                errorMessage = String(format: template, error.localizedDescription)
            }
        } else {
            // Database is accessible
            syncStatus = .synced
            errorMessage = nil
            Log.info("[CloudKitSyncMonitor] CloudKit database accessible, sync ready", category: .sync)
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

        #if DEBUG
        guard !Self.isRunningHostedUnitTests else {
            syncStatus = .synced
            errorMessage = nil
            return
        }
        #endif

        // Trigger Core Data save to push changes to CloudKit
        let context = container.viewContext
        if context.hasChanges {
            do {
                try context.save()
                Log.info("[CloudKitSyncMonitor] Local changes saved, triggering CloudKit sync", category: .sync)
            } catch {
                syncStatus = .error
                let template = NSLocalizedString(
                    "sync.error.saveFailed",
                    value: "保存本地修改失败：%@",
                    comment: "Shown when forceSync fails to save the viewContext; %@ is system error"
                )
                errorMessage = String(format: template, error.localizedDescription)
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
                Task { @MainActor [weak self] in
                    self?.syncStatus = .error
                    let template = NSLocalizedString(
                        "sync.error.accountCheckFailed",
                        value: "账户检查失败：%@",
                        comment: "Shown when account-status check fails inside forceSync; %@ is system error"
                    )
                    self?.errorMessage = String(format: template, error.localizedDescription)
                }
                return
            }

            guard status == .available else {
                Task { @MainActor [weak self] in
                    self?.syncStatus = .notSignedIn
                    self?.errorMessage = NSLocalizedString(
                        "sync.error.accountUnavailable",
                        value: "iCloud 账户不可用",
                        comment: "Shown when forceSync sees a non-available iCloud account"
                    )
                }
                return
            }

            // Wait a moment for CloudKit to process the changes.
            // 注意:这个 2s 是在用户主动 forceSync (pull-to-refresh) 之后触发的,只是给 CloudKit
            // 上一步的 viewContext.save() 一点处理时间,然后用 verifySync 做一次只读 zone fetch
            // 验证可达性。**reachability ≠ export 完成**——`verifySync` 成功仅说明
            // CloudKit database 可访问,并不保证刚保存的数据已经上传完。真正"导出完成"信号
            // 只能从 `NSPersistentCloudKitContainer.eventChangedNotification` (.export, succeeded)
            // 拿,见 handleCloudKitEvent。这里把 .synced 弱化到只覆盖"reachable + 没账户错误"
            // 的语义,实际 export 完成由事件回调最终矫正。
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.verifySync()
            }
        }
    }

    private func verifySync() {
        // Verify CloudKit connectivity without querying record fields. Actual export completion
        // still comes from NSPersistentCloudKitContainer.eventChangedNotification.
        let ckContainer = CKContainer(identifier: "iCloud.com.Mingyi.Lumory")
        let database = ckContainer.privateCloudDatabase

        // 同 `checkDatabaseAccessibility`:CK callback 后台队列触发,Task @MainActor hop。
        database.fetchAllRecordZones { [weak self] _, error in
            Task { @MainActor [weak self] in
                self?.handleSyncVerificationResult(error: error)
            }
        }
    }

    private func handleSyncVerificationResult(error: Error?) {
        if let error = error {
            let ckError = error as? CKError
            if ckError?.code == .zoneNotFound || ckError?.code == .userDeletedZone {
                // This is normal for new installations
                syncStatus = .synced
                errorMessage = nil
                Log.info("[CloudKitSyncMonitor] Sync verified (new installation)", category: .sync)
            } else {
                syncStatus = .error
                let template = NSLocalizedString(
                    "sync.error.verifyFailed",
                    value: "同步校验失败：%@",
                    comment: "Shown when forceSync's verify-step query fails; %@ is system error"
                )
                errorMessage = String(format: template, error.localizedDescription)
                Log.error("[CloudKitSyncMonitor] Sync verification error: \(error)", category: .sync)
            }
        } else {
            // ⚠️ 这一步只能证明 CloudKit zone 可达 + 上次保存的 viewContext 没炸,
            // **不能**证明刚 push 的本地变更已经导出完。真正"export succeeded"信号
            // 来自 `NSPersistentCloudKitContainer.eventChangedNotification` 的 .export
            // 事件 (handleCloudKitEvent),最终状态由那条路径矫正。这里维持 .synced
            // 是为了让用户主动 pull-to-refresh 后立刻看到一个非"unknown/error"的反馈,
            // 不要把它当成 export 完成的权威信号。
            syncStatus = .synced
            errorMessage = nil
            Log.info(
                "[CloudKitSyncMonitor] CloudKit reachable; export completion is confirmed via eventChangedNotification",
                category: .sync
            )
        }
    }

    deinit {
        // Block-form `addObserver` returns opaque tokens that `removeObserver(self)`
        // does NOT handle—those would leak forever. Release them explicitly here.
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
        observerTokens.removeAll()
    }
}
