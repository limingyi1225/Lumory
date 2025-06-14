import Foundation
import CoreData
import CloudKit

/// 同步诊断服务，用于检测和报告iCloud同步问题
struct SyncDiagnosticService {
    
    static func resetCloudKitSchema(container: NSPersistentCloudKitContainer) {
        print("[SyncDiagnosticService] Attempting to check CloudKit schema...")
        
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
        print("[SyncDiagnosticService] Schema diagnostics are only available in DEBUG mode")
        #endif
    }
    
    static func diagnoseCloudKitError(_ error: CKError) {
        print("[SyncDiagnosticService] CloudKit Error Code: \(error.code.rawValue)")
        print("[SyncDiagnosticService] Error Description: \(error.localizedDescription)")
        
        switch error.code {
        case .badDatabase:
            print("[SyncDiagnosticService] Bad database - The CloudKit database may need to be reset")
        case .permissionFailure:
            print("[SyncDiagnosticService] Permission failure - Check CloudKit entitlements and capabilities")
        case .invalidArguments:
            print("[SyncDiagnosticService] Invalid arguments - Check the record types and field names")
        case .serverRejectedRequest:
            print("[SyncDiagnosticService] Server rejected request - The schema might already exist or have conflicts")
        case .assetFileNotFound:
            print("[SyncDiagnosticService] Asset file not found - Check binary data storage")
        case .incompatibleVersion:
            print("[SyncDiagnosticService] Incompatible version - The app version might not match the CloudKit schema")
        case .constraintViolation:
            print("[SyncDiagnosticService] Constraint violation - Check for unique constraints")
        default:
            print("[SyncDiagnosticService] Other error: \(error)")
        }
        
        // Check for partial errors
        if let partialErrors = error.partialErrorsByItemID {
            print("[SyncDiagnosticService] Partial errors found:")
            for (itemID, partialError) in partialErrors {
                print("[SyncDiagnosticService]   Item: \(itemID), Error: \(partialError)")
            }
        }
    }
    
    /// 执行完整的同步诊断
    static func performDiagnostic() async -> SyncDiagnosticResult {
        print("[SyncDiagnostic] Starting comprehensive sync diagnostic...")
        
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
            
            // Perform a simple query to test connectivity
            let query = CKQuery(recordType: "CD_DiaryEntry", predicate: NSPredicate(value: true))
            
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
        guard let iCloudContainer = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") else {
            return false
        }
        
        // Test write access
        let testFile = iCloudContainer.appendingPathComponent("diagnostic_test.tmp")
        do {
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: testFile)
            return true
        } catch {
            print("[SyncDiagnostic] iCloud container access failed: \(error)")
            return false
        }
    }
    
    private static func checkCoreDataStoreStatus() -> (isHealthy: Bool, error: String?) {
        let container = PersistenceController.shared.container
        
        // Check if the store is loaded
        guard !container.persistentStoreDescriptions.isEmpty else {
            return (false, "No persistent stores configured")
        }
        
        // Try to perform a simple fetch
        let context = container.viewContext
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.fetchLimit = 1
        
        do {
            _ = try context.fetch(request)
            return (true, nil)
        } catch {
            return (false, "Core Data fetch failed: \(error.localizedDescription)")
        }
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
