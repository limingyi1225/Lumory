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
    // 回到原来的 `let` 形式——之前改成 @StateObject 是为了让 `isStoreLoadFailed` 能驱动 UI，
    // 但暂时没视图消费它，反而在真机启动时触发了白屏（疑似 @StateObject 与 App 结构在 iOS 26 的
    // 生命周期交互异常）。`let + singleton` 是稳定工作过的形式，保持这个不动。
    let persistenceController = PersistenceController.shared
    @StateObject private var importService = CoreDataImportService()
    @StateObject private var syncMonitor = CloudKitSyncMonitor(container: PersistenceController.shared.container)
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLanguage") private var appLanguage: String = {
        let currentLocale = Locale.current.identifier
        if currentLocale.hasPrefix("zh") {
            return "zh-Hans"
        } else {
            return "en"
        }
    }()
    @State private var showSplash: Bool = true
    @State private var remoteChangeObserver: NSObjectProtocol?
    @State private var memoryWarningObserver: NSObjectProtocol?
    init() {
        #if canImport(UIKit)
        UITableView.appearance().separatorStyle = .none
        UITableView.appearance().tableFooterView = UIView()
        #endif

        // 注意：以前这里有 checkDatabaseHealth()——和 PersistenceController 内部的那条
        // 一起是双重预检，且会在 WAL 被其他进程持有时误报。已经移除（PersistenceController
        // 的 loadPersistentStores 错误分支会走 DatabaseRecoveryService，有用户弹窗确认）。

        // App Store screenshot 用的 sample data 注入。仅 DEBUG + 显式 launchArg 才生效，
        // 见 UITestSampleData.swift。这条路径同步执行（~40ms），需要发生在 DataMigration 之前
        // 因为它会先 batch delete 所有 entries——如果迁移塞了一批数据进来，反而会被擦掉。
        #if DEBUG
        UITestSampleData.seedIfNeeded(into: persistenceController)
        #endif

        // v2 JSON → Core Data 的一次性迁移。以前在 init() 里同步调用 → `performAndWait`
        // 在主线程上跑几百条 JSON 解码 + Core Data insert，老用户首次升级会看到 App 卡
        // 数秒、极端情况下 watchdog 杀进程。挪到 userInitiated 后台 Task：
        //  - 幂等：migrationKey UserDefaults 守卫 + 插入前 UUID 去重（DataMigrationService 内）
        //  - 迁移完成后 NSPersistentCloudKitContainer 的 save 会触发 @FetchRequest 自动刷新 UI
        //  - PersistenceController.shared 的 singleton init 已经在 App 属性初始化器里完成，
        //    此处 Task 跑时 store 必然已加载
        Task.detached(priority: .userInitiated) {
            DataMigrationService.performMigrationIfNeeded()
        }
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

        // wordCount 回填：每次启动扫一遍 wordCount=0 的条目。
        // 没有 flag，因为 CloudKit 后续 pull 进来的老条目也需要补算——
        // fetchCount 有命中才真执行，代价只是一条 SQL count。本地计算、不走网络，
        // 和 Settings 的"一键重建"也用同一 service 但不共享 progress（这里走的是
        // `backfillIfNeeded`，"一键重建"走 `forceBackfill`，都是幂等的）。
        Task.detached(priority: .utility) {
            await WordCountBackfillService.backfillIfNeeded()
        }

        // NOTE：以前这里还自动跑过 `EmbeddingBackfillService.shared.backfillAll()`
        // 和 `ThemeBackfillService.shared.backfillProblems()`，想给 v3→v4 老用户
        // 免手动地把 embedding / themes 补齐。实际踩到：
        //   1. 这俩 service 是 `.shared` singleton，auto-backfill 和 Settings 的"一键重建索引"
        //      并发跑时 `runningTask` guard 不是 actor-safe，进度条（processed/total/failed）
        //      被串；"一键重建"读到的是 auto 的中间 failed 计数，UI 报"向量 N 失败"。
        //   2. App 启动瞬间网络常不稳（刚 resume / DNS 未就绪 / CloudKit 占带宽），
        //      auto-backfill 失败率高但用户无从察觉，只在之后点"一键重建"时爆出。
        //   3. 新用户没有历史 embedding/themes 要补，auto 路径对他们完全没价值。
        // 结论：不自动跑。v3→v4 用户首次升级后主动去 Settings 点一次"一键重建索引"，
        // 流程清晰、进度 UI 真实反映网络问题、失败可重试。之后要加 auto 需要先把 service
        // 换成 actor-safe 的 lifecycle 管理。
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
        // Screenshot 自动化模式:跳过弹窗,否则会盖在 Home 上把首屏截烂。
        // 真实运行用户必须看到这俩弹窗,所以只在显式 launchArg 时才跳。
        #if DEBUG
        if UITestSampleData.isActive { return }
        #endif

        #if canImport(UIKit) && !os(macOS)
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: { granted in
                if !granted {
                    Log.info("Microphone permission denied", category: .ui)
                }
            })
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                if !granted {
                    Log.info("Microphone permission denied", category: .ui)
                }
            }
        }
        #endif

        SFSpeechRecognizer.requestAuthorization { status in
            switch status {
            case .authorized:
                break
            default:
                Log.info("Speech recognition permission status: \(status)", category: .ui)
            }
        }
    }
    
    private func migrateExistingImagesToiCloud() {
        // 启动时不阻塞主线程：一次性把旧日记的图片迁进 CloudKit sync 字段。
        // 走后台 context，所有对 managed object 属性的读写都在其专属 queue 上进行。
        Task.detached(priority: .utility) {
            let bg = PersistenceController.shared.container.newBackgroundContext()
            await bg.perform {
                let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
                guard let entries = try? bg.fetch(request) else { return }

                var migrated = 0
                for entry in entries where !entry.imageFileNameArray.isEmpty && entry.imagesData == nil {
                    let images = entry.imageFileNameArray.compactMap { entry.loadImageData(fileName: $0) }
                    guard !images.isEmpty else { continue }

                    let compressed = images.map { DiaryEntry.compressImageData($0) }
                    if let data = try? NSKeyedArchiver.archivedData(withRootObject: compressed, requiringSecureCoding: false) {
                        entry.imagesData = data
                        migrated += 1
                    }
                }

                if migrated > 0, bg.hasChanges {
                    do {
                        try bg.save()
                        Log.info("[ChronoteApp] Migrated images for \(migrated) entries to sync data", category: .ui)
                    } catch {
                        Log.error("[ChronoteApp] Failed to save image migration: \(error)", category: .ui)
                    }
                }
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
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
            .environment(\.aiService, OpenAIService.shared)
            .environmentObject(importService)
            .environmentObject(syncMonitor)
            .onAppear {
                showSplash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    showSplash = false
                }
                // CloudKit pull 进来新 entries 时触发一次 wordCount 回算——
                // NSPersistentCloudKitContainer 不会自动补派生字段，我们必须自己扫。
                if remoteChangeObserver == nil {
                    remoteChangeObserver = NotificationCenter.default.addObserver(
                        forName: .NSPersistentStoreRemoteChange,
                        object: persistenceController.container.persistentStoreCoordinator,
                        queue: nil
                    ) { _ in
                        Task.detached(priority: .utility) {
                            await WordCountBackfillService.backfillIfNeeded()
                        }
                    }
                }

                // 系统内存吃紧时主动释放图片 cache 和 URLCache，降低被 jetsam kill 的概率。
                // NSCache 本身对内存压力有响应，但系统 evict 策略只基于自身 cost，不会立刻清空；
                // 显式响应 warning 通知能在 iPad 多任务 / 长会话场景下明显降低白屏率。
                #if canImport(UIKit)
                if memoryWarningObserver == nil {
                    memoryWarningObserver = NotificationCenter.default.addObserver(
                        forName: UIApplication.didReceiveMemoryWarningNotification,
                        object: nil,
                        queue: .main
                    ) { _ in
                        DiaryEntry.clearImageCache()
                        URLCache.shared.removeAllCachedResponses()
                        Log.info("[ChronoteApp] didReceiveMemoryWarning — cleared image cache + URLCache", category: .ui)
                    }
                }
                #endif
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
        }
    }

    /// App 在后台/前台切换时的清理入口。
    /// - 后台化：保存未落盘的 viewContext（用户正在输入时被电话打断的情况常见），
    ///   避免 OS 杀后台时丢掉当前编辑。
    /// - 失去活动：暂时不用处理，留 hook 以后可用。
    /// - 重新活动：触发一次 CloudKit sync 检查，捡起刚刚的远端变更。
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // 保存所有 pending 编辑——防止 OS 后台回收时丢失用户输入
            let ctx = persistenceController.container.viewContext
            if ctx.hasChanges {
                do {
                    try ctx.save()
                    Log.info("[ChronoteApp] scenePhase=background — flushed viewContext", category: .ui)
                } catch {
                    Log.error("[ChronoteApp] scenePhase=background — save failed: \(error)", category: .ui)
                }
            }
        case .active:
            // 重新上前台：主动触发一次 CloudKit 状态检查，顺带把远端变更拉下来
            syncMonitor.checkCloudKitStatus()
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}
