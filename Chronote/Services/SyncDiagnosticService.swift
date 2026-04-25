import Foundation
import CoreData
import CloudKit

/// 同步诊断服务，用于检测和报告iCloud同步问题
struct SyncDiagnosticService {
    
    static func resetCloudKitSchema(container: NSPersistentCloudKitContainer) {
        Log.info("[SyncDiagnosticService] Attempting to check CloudKit schema...", category: .sync)
        
        #if DEBUG
        // The initializeCloudKitSchema method doesn't throw errors in newer versions
        // It's also only available for initializing, not resetting
        print("[SyncDiagnosticService] Note: CloudKit schema initialization is automatic with NSPersistentCloudKitContainer")
        print("[SyncDiagnosticService] Schema issues typically require:")
        print("[SyncDiagnosticService] 1. Deleting the app and reinstalling")
        print("[SyncDiagnosticService] 2. Resetting the CloudKit development environment in CloudKit Dashboard")
        print("[SyncDiagnosticService] 3. Ensuring proper entitlements and container configuration")
        
        // Verify container configuration
        if let storeDescription = container.persistentStoreDescriptions.first,
           let cloudKitOptions = storeDescription.cloudKitContainerOptions {
            print("[SyncDiagnosticService] CloudKit container: \(cloudKitOptions.containerIdentifier)")
        } else {
            print("[SyncDiagnosticService] WARNING: No CloudKit options found in store description")
        }
        #else
        Log.info("[SyncDiagnosticService] Schema diagnostics are only available in DEBUG mode", category: .sync)
        #endif
    }
    
    /// 执行完整的同步诊断
    static func performDiagnostic() async -> SyncDiagnosticResult {
        Log.info("[SyncDiagnostic] Starting comprehensive sync diagnostic...", category: .sync)
        
        var issues: [SyncIssue] = []
        var recommendations: [String] = []
        
        // 1. 检查iCloud账户状态
        let accountStatus = await checkiCloudAccountStatus()
        if !accountStatus.isAvailable {
            issues.append(.iCloudNotSignedIn)
            recommendations.append("Please sign in to iCloud in System Settings")
        }
        
        // 2. 检查网络连接
        let networkStatus = await checkNetworkConnectivity()
        if !networkStatus {
            issues.append(.networkUnavailable)
            recommendations.append("Check your internet connection")
        }
        
        // 3. 检查iCloud容器访问
        let containerAccess = checkiCloudContainerAccess()
        if !containerAccess {
            issues.append(.iCloudContainerInaccessible)
            recommendations.append("iCloud container is not accessible")
        }
        
        // 4. 检查Core Data存储状态
        let storeStatus = checkCoreDataStoreStatus()
        if !storeStatus.isHealthy {
            issues.append(.coreDataStoreCorrupted)
            recommendations.append("Core Data store may be corrupted")
        }
        
        // 5. 检查CloudKit配置
        let cloudKitConfig = checkCloudKitConfiguration()
        if !cloudKitConfig {
            issues.append(.cloudKitMisconfigured)
            recommendations.append("CloudKit configuration is incorrect")
        }
        
        let severity: SyncDiagnosticSeverity
        if issues.contains(where: { $0.isCritical }) {
            severity = .critical
        } else if !issues.isEmpty {
            severity = .warning
        } else {
            severity = .healthy
        }
        
        return SyncDiagnosticResult(
            severity: severity,
            issues: issues,
            recommendations: recommendations,
            timestamp: Date()
        )
    }
    
    // MARK: - Individual Checks
    
    private static func checkiCloudAccountStatus() async -> (isAvailable: Bool, error: String?) {
        return await withCheckedContinuation { continuation in
            let container = CKContainer(identifier: "iCloud.com.Mingyi.Lumory")
            container.accountStatus { status, error in
                if let error = error {
                    continuation.resume(returning: (false, error.localizedDescription))
                } else {
                    continuation.resume(returning: (status == .available, nil))
                }
            }
        }
    }
    
    private static func checkNetworkConnectivity() async -> Bool {
        return await withCheckedContinuation { continuation in
            let container = CKContainer(identifier: "iCloud.com.Mingyi.Lumory")
            let database = container.privateCloudDatabase
            
            // Perform a simple query to test connectivity.
            // **必须**用带 built-in 索引的谓词——`NSPredicate(value: true)` 在 production schema
            // 没对应 query index，CloudKit 会抛 invalidArguments，被此函数误判为 `.networkUnavailable`。
            // CloudKitSyncMonitor.swift 已改，这里是漏改的 sibling call site。
            let query = CKQuery(
                recordType: "CD_DiaryEntry",
                predicate: NSPredicate(format: "modificationDate > %@", Date.distantPast as NSDate)
            )
            
            if #available(macOS 12.0, iOS 15.0, *) {
                database.fetch(withQuery: query, inZoneWith: nil, desiredKeys: nil, resultsLimit: 1) { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: true)
                    case .failure(let error):
                        if let ckError = error as? CKError {
                            let isNetworkError = ckError.code == .networkUnavailable || ckError.code == .networkFailure
                            continuation.resume(returning: !isNetworkError)
                        } else {
                            continuation.resume(returning: false)
                        }
                    }
                }
            } else {
                database.perform(query, inZoneWith: nil) { _, error in
                    if let error = error as? CKError {
                        let isNetworkError = error.code == .networkUnavailable || error.code == .networkFailure
                        continuation.resume(returning: !isNetworkError)
                    } else {
                        continuation.resume(returning: true)
                    }
                }
            }
        }
    }
    
    private static func checkiCloudContainerAccess() -> Bool {
        // 历史上这里是写一个 `diagnostic_test.tmp` 到 ubiquity container 来探活,但
        // `PersistenceController.swift:319-322` 明确说不要走 ubiquity 路径(NSPersistentCloudKitContainer
        // 用的是 CloudKit 私有数据库,不是 iCloud Drive 的 ubiquity 文件存储,写测试文件既污染
        // 用户的 iCloud Drive,也不能反映 CloudKit 同步状态)。改成纯 token 探活:
        //  - `ubiquityIdentityToken != nil` 表示用户登录了 iCloud 且本 app 容器是 reachable 的;
        //  - 真正"CloudKit 数据库可达"由上一步 `checkNetworkConnectivity()` 的 query 判定。
        return FileManager.default.ubiquityIdentityToken != nil
    }

    /// `viewContext` 是 `mainQueueConcurrencyType`,Core Data 强制要求只能在主线程访问。
    /// `performDiagnostic()` 是 async non-MainActor 调用栈(SettingsView.runSyncDiagnostic
    /// 在普通 `Task {}` 里 await 这个函数),从那里直接 `container.viewContext.fetch(...)`
    /// 就是线程违规,会随机静默损坏对象图。这里改用 `newBackgroundContext()` —— 自己的私有队列,
    /// 用 `performAndWait` 把 fetch 包到队列上,任意线程都安全。
    private static func checkCoreDataStoreStatus() -> (isHealthy: Bool, error: String?) {
        let container = PersistenceController.shared.container

        // Check if the store is loaded
        guard !container.persistentStoreDescriptions.isEmpty else {
            return (false, "No persistent stores configured")
        }

        let context = container.newBackgroundContext()
        var result: (isHealthy: Bool, error: String?) = (true, nil)
        context.performAndWait {
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.fetchLimit = 1
            do {
                _ = try context.fetch(request)
                result = (true, nil)
            } catch {
                result = (false, "Core Data fetch failed: \(error.localizedDescription)")
            }
        }
        return result
    }
    
    private static func checkCloudKitConfiguration() -> Bool {
        let container = PersistenceController.shared.container
        
        // Check if CloudKit is properly configured
        guard let storeDescription = container.persistentStoreDescriptions.first else {
            return false
        }
        
        return storeDescription.cloudKitContainerOptions != nil
    }
    
    /// 生成诊断报告文本
    static func generateDiagnosticReport(_ result: SyncDiagnosticResult) -> String {
        var report = "=== iCloud Sync Diagnostic Report ===\n"
        report += "Generated: \(DateFormatter.localizedString(from: result.timestamp, dateStyle: .medium, timeStyle: .medium))\n\n"
        
        report += "Overall Status: \(result.severity.displayName)\n\n"
        
        if result.issues.isEmpty {
            report += "✅ No issues detected. Sync should be working properly.\n"
        } else {
            report += "Issues Found:\n"
            for issue in result.issues {
                report += "• \(issue.description)\n"
            }
            
            report += "\nRecommendations:\n"
            for recommendation in result.recommendations {
                report += "• \(recommendation)\n"
            }
        }
        
        return report
    }
}

// MARK: - Supporting Types

struct SyncDiagnosticResult {
    let severity: SyncDiagnosticSeverity
    let issues: [SyncIssue]
    let recommendations: [String]
    let timestamp: Date
}

enum SyncDiagnosticSeverity {
    case healthy
    case warning
    case critical
    
    var displayName: String {
        switch self {
        case .healthy: return "Healthy"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

enum SyncIssue {
    case iCloudNotSignedIn
    case networkUnavailable
    case iCloudContainerInaccessible
    case coreDataStoreCorrupted
    case cloudKitMisconfigured
    
    var description: String {
        switch self {
        case .iCloudNotSignedIn:
            return "Not signed in to iCloud"
        case .networkUnavailable:
            return "Network connection unavailable"
        case .iCloudContainerInaccessible:
            return "iCloud container is not accessible"
        case .coreDataStoreCorrupted:
            return "Core Data store may be corrupted"
        case .cloudKitMisconfigured:
            return "CloudKit is not properly configured"
        }
    }
    
    var isCritical: Bool {
        switch self {
        case .iCloudNotSignedIn, .coreDataStoreCorrupted, .cloudKitMisconfigured:
            return true
        case .networkUnavailable, .iCloudContainerInaccessible:
            return false
        }
    }
}
