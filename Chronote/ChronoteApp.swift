//
//  ChronoteApp.swift
//  Chronote
//
//  Created by Isaac on 5/24/25.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import CoreData
import AVFoundation
import Speech

@main
struct ChronoteApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var importService = CoreDataImportService()
    @StateObject private var syncMonitor = CloudKitSyncMonitor(container: PersistenceController.shared.container)
    @AppStorage("appLanguage") private var appLanguage: String = {
        let currentLocale = Locale.current.identifier
        if currentLocale.hasPrefix("zh") {
            return "zh-Hans"
        } else {
            return "en"
        }
    }()
    @State private var showSplash: Bool = true
    init() {
        #if canImport(UIKit)
        UITableView.appearance().separatorStyle = .none
        UITableView.appearance().tableFooterView = UIView()
        #endif
        
        // Check database health before proceeding
        checkDatabaseHealth()
        
        // 执行数据迁移（从 JSON 到 Core Data）
        DataMigrationService.performMigrationIfNeeded()
        requestPermissions()
        
        // Pre-warm animations for better performance
        preWarmAnimations()
        
        // 迁移图片到iCloud
        migrateExistingImagesToiCloud()
        
        // Debug CloudKit issues
        #if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            print("[ChronoteApp] Running CloudKit diagnostics...")
            PersistenceController.shared.debugCloudKitIssues()
        }
        #endif
        
        // Cleanup old backups periodically
        DatabaseRecoveryService.shared.cleanupOldBackups()
    }
    
    private func checkDatabaseHealth() {
        // Get the database URL
        guard let storeURL = persistenceController.container.persistentStoreDescriptions.first?.url else {
            return
        }
        
        // Check if database exists and is healthy
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let isHealthy = DatabaseRecoveryService.shared.checkDatabaseHealth(at: storeURL)
            if !isHealthy {
                print("[ChronoteApp] Database health check failed - corruption may be present")
            }
        }
    }
    
    // Pre-warm animations for better performance
    private func preWarmAnimations() {
        // Pre-compute common animations to reduce first-time lag
        _ = AnimationConfig.standardResponse
        _ = AnimationConfig.gentleSpring
        _ = AnimationConfig.bouncySpring
        _ = AnimationConfig.breathingAnimation
        
        // Pre-warm CADisplayLink if needed
        #if canImport(UIKit)
        let _ = CAFrameRateRange.uiUpdates
        #endif
    }
    
    // 请求录音权限和语音识别权限
    private func requestPermissions() {
        #if canImport(UIKit) && !os(macOS)
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: { granted in
                if !granted {
                    print("Microphone permission denied")
                }
            })
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                if !granted {
                    print("Microphone permission denied")
                }
            }
        }
        #endif

        SFSpeechRecognizer.requestAuthorization { status in
            switch status {
            case .authorized:
                break
            default:
                print("Speech recognition permission status: \(status)")
            }
        }
    }
    
    private func migrateExistingImagesToiCloud() {
        let context = persistenceController.container.viewContext
        let fetchRequest: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        
        do {
            let entries = try context.fetch(fetchRequest)
            var migratedCount = 0
            
            for entry in entries {
                // Migrate images to sync data if not already done
                if !entry.imageFileNameArray.isEmpty && entry.imagesData == nil {
                    let images = entry.loadAllImageData()
                    if !images.isEmpty {
                        entry.saveImagesForSync(images)
                        migratedCount += 1
                    }
                }
            }
            
            if migratedCount > 0 {
                try context.save()
                print("[ChronoteApp] Migrated images for \(migratedCount) entries to sync data")
            }
        } catch {
            print("[ChronoteApp] Failed to migrate images: \(error)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(macCatalyst)
            MacNavigationView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(importService)
                .environmentObject(syncMonitor)
                .id(appLanguage)
                .onAppear {
                    // Configure Mac-specific settings
                    DispatchQueue.main.async {
                        UIApplication.shared.configureForMac()
                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                            MacToolbarHelper.addToolbarItems(to: windowScene)
                        }
                    }
                }
            #else
            ZStack {
                if !showSplash {
                    HomeView()
                        .transition(.opacity)
                        .id(appLanguage) // Force refresh when language changes
                }

                if showSplash {
                    SplashView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.8), value: showSplash)
            .environment(\.managedObjectContext, persistenceController.container.viewContext)
            .environmentObject(importService)
            .environmentObject(syncMonitor)
            .onAppear {
                showSplash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { 
                    showSplash = false
                }
            }
            #endif
        }
        #if targetEnvironment(macCatalyst)
        .windowResizability(.contentSize)
        .defaultSize(width: 1200, height: 700)
        .commands {
            MacMenuCommands()
        }
        #endif
    }
}
