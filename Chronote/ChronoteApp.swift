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
#if canImport(UserNotifications)
import UserNotifications
#endif

@main
struct ChronoteApp: App {
    // 回到原来的 `let` 形式——之前改成 @StateObject 是为了让 `isStoreLoadFailed` 能驱动 UI，
    // 但暂时没视图消费它，反而在真机启动时触发了白屏（疑似 @StateObject 与 App 结构在 iOS 26 的
    // 生命周期交互异常）。`let + singleton` 是稳定工作过的形式，保持这个不动。
    let persistenceController = PersistenceController.shared
    @StateObject private var importService = CoreDataImportService()
    @StateObject private var syncMonitor = CloudKitSyncMonitor(container: PersistenceController.shared.container)
    @ObservedObject private var appLockService = AppLockService.shared
    @ObservedObject private var milestoneService = StreakMilestoneService.shared
    @Environment(\.scenePhase) private var scenePhase
    // **App Group store** —— widget 跟主 App 共享同一份 `appLanguage`,主 App 切语言 widget 跟着走。
    // 读取链在 `LocalizationHelper.appLanguageBundle`,有 standard 回退,不会因 App Group 暂不可用而崩。
    @AppStorage("appLanguage", store: AppGroup.userDefaults) private var appLanguage: String = {
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
    @State private var storeLoadErrorMessage: String?
    private static let deleteCacheCompatibilityDoneKey = "lumory.compatibility.20260504.deleteCacheCleanup.done"

    init() {
        #if canImport(UIKit)
        UITableView.appearance().separatorStyle = .none
        UITableView.appearance().tableFooterView = UIView()
        #endif
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().delegate = ReminderNotificationRouter.shared
        #endif

        // **`appLanguage` 一次性迁移**:之前所有 `@AppStorage("appLanguage")` 都写到 `UserDefaults.standard`,
        // 这次切到了 `AppGroup.userDefaults` 让 widget 能读同一份偏好。老用户升级后 App Group
        // store 还没写过,@AppStorage 会读到 nil 落到 default(系统 locale 推断),如果用户之前手动
        // 选过中文(但设备是英文)、或选过英文(但设备是中文),会被翻到错的语言。
        // 这里 idempotent 一次性 copy:App Group 没写过且 standard 里有值 → 拷过去。运行多次无副作用。
        let standardDefaults = UserDefaults.standard
        let groupDefaults = AppGroup.userDefaults
        if groupDefaults.object(forKey: "appLanguage") == nil,
           let legacy = standardDefaults.string(forKey: "appLanguage") {
            groupDefaults.set(legacy, forKey: "appLanguage")
        }

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
            Log.info("[ChronoteApp] Running CloudKit diagnostics...", category: .sync)
            PersistenceController.shared.debugCloudKitIssues()
        }
        #endif

        // Cleanup old backups periodically
        DatabaseRecoveryService.shared.cleanupOldBackups()

        // 老版本单条删除没有完整清理所有派生缓存。Core Data 里的日记本身已经删除,
        // 但首页/AskPast 提示缓存、widget snapshot、theme alias pending 可能仍引用已删主题。
        // 升级后跑一次轻量 cleanup:不扫正文、不删真实 entry,只丢可再生缓存并让 widget 重投影当前数据库。
        runDeleteCacheCompatibilityCleanup()

        // wordCount 回填：每次启动扫一遍 wordCount=0 的条目。
        // 没有 flag，因为 CloudKit 后续 pull 进来的老条目也需要补算——
        // fetchCount 有命中才真执行，代价只是一条 SQL count。本地计算、不走网络，
        // 和 Settings 的"一键重建"也用同一 service 但不共享 progress（这里走的是
        // `backfillIfNeeded`，"一键重建"走 `forceBackfill`，都是幂等的）。
        Task.detached(priority: .utility) {
            await WordCountBackfillGate.shared.runIfIdle {
                await WordCountBackfillService.backfillIfNeeded()
            }
        }

        // 启动时刷一次 widget snapshot —— PersistenceController 的 DidSave / RemoteChange
        // observer 只在"有写"时才 fire,冷启动后第一次 widget reload 需要 snapshot 落盘。
        // service 内部 250ms debounce + isInMemory guard,跟 backfill 并发也安全。
        let persistenceForWidget = persistenceController
        Task.detached(priority: .utility) {
            await WidgetSnapshotService.shared.requestRefresh(persistence: persistenceForWidget)
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

    private func runDeleteCacheCompatibilityCleanup() {
        guard !persistenceController.isInMemory else { return }

        let defaults = AppGroup.userDefaults
        let doneKey = Self.deleteCacheCompatibilityDoneKey
        guard !defaults.bool(forKey: doneKey) else { return }

        let persistence = persistenceController
        Task { @MainActor in
            PromptSuggestionEngine.shared.clearCache()
            await WidgetSnapshotService.shared.clear()
            await ThemeAliasResolver.shared.cleanupOrphanedPending()
            await WidgetSnapshotService.shared.requestRefresh(persistence: persistence, bypassDebounce: true)
            defaults.set(true, forKey: doneKey)
            Log.info("[ChronoteApp] Delete cache compatibility cleanup finished", category: .persistence)
        }
    }
    
    // Pre-warm animations for better performance
    private func preWarmAnimations() {
        // Pre-compute common animations to reduce first-time lag
        _ = AnimationConfig.standardResponse
        _ = AnimationConfig.gentleSpring

        // Pre-warm CADisplayLink if needed
        #if canImport(UIKit)
        _ = CAFrameRateRange.uiUpdates
        #endif
    }
    
    // 请求录音权限。语音识别走 OpenAI 后端转写,不再需要 Speech.framework 权限。
    private func requestPermissions() {
        // Screenshot 自动化模式:跳过弹窗,否则会盖在 Home 上把首屏截烂。
        // 真实运行用户必须看到弹窗,所以只在显式 launchArg 时才跳。
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
    }
    
    private func migrateExistingImagesToiCloud() {
        // 启动时不阻塞主线程：把旧日记的图片迁进 CloudKit sync 字段。
        // 不加一次性 done flag：CloudKit / restore 可能在首次空扫描之后才拉到旧条目，幂等重扫更安全。
        // 走后台 context，所有对 managed object 属性的读写都在其专属 queue 上进行。

        Task.detached(priority: .utility) {
            let bg = PersistenceController.shared.container.newBackgroundContext()
            await bg.perform {
                let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
                request.predicate = NSPredicate(
                    format: "imageFileNames != nil AND imageFileNames != '' AND imagesData == nil"
                )
                request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: true)]
                request.fetchBatchSize = 50
                guard let entries = try? bg.fetch(request) else { return }
                guard !entries.isEmpty else { return }

                var migrated = 0
                var scanned = 0
                var saveFailed = false

                for entry in entries {
                    scanned += 1
                    let fileNames = entry.imageFileNameArray
                    let images = fileNames.compactMap { DiaryEntry.loadImageData(fileName: $0) }
                    guard !images.isEmpty, images.count == fileNames.count else {
                        continue
                    }

                    let compressed = images.map { DiaryEntry.compressImageData($0) }
                    if let data = try? NSKeyedArchiver.archivedData(withRootObject: compressed, requiringSecureCoding: true) {
                        entry.imagesData = data
                        migrated += 1
                    }

                    if scanned % 50 == 0, bg.hasChanges {
                        do {
                            try bg.save()
                        } catch {
                            bg.rollback()
                            saveFailed = true
                            Log.error("[ChronoteApp] Failed to save image migration batch: \(error)", category: .ui)
                            break
                        }
                    }
                }

                if !saveFailed, bg.hasChanges {
                    do {
                        try bg.save()
                    } catch {
                        bg.rollback()
                        saveFailed = true
                        Log.error("[ChronoteApp] Failed to save image migration: \(error)", category: .ui)
                    }
                }

                if !saveFailed {
                    if migrated > 0 {
                        Log.info("[ChronoteApp] Migrated images for \(migrated) entries to sync data", category: .ui)
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

                // Streak milestone celebration — 命中 7/14/30/60/100/(+100) 时盖一个 overlay,
                // ~3s 自动 fade。比 LockScreen zIndex 低,锁屏时不会同时弹出。
                if let milestone = milestoneService.pendingMilestone {
                    StreakMilestoneCelebration(milestone: milestone) {
                        milestoneService.dismiss()
                    }
                    .transition(.opacity)
                    .zIndex(50)
                }

                // App lock — 启用 + 锁定时盖在所有内容(含 splash + milestone)上,确保任何状态都看不到日记。
                if appLockService.isEnabled && appLockService.isLocked {
                    LockScreenView()
                        .transition(.opacity)
                        .zIndex(100)
                }

                // Global toast overlay(P0-2)— 高频成功反馈(删 / 存 / 发 / 合并主题)统一从这里冒,
                // sheet / 全屏 cover / Settings 深层都能看到。zIndex 在 lock screen(100)之下,
                // 因为锁屏时不应该泄漏 toast 内容到锁屏之上。milestone(50)之上,toast 优先。
                LumoryToastOverlay()
                    .ignoresSafeArea(.keyboard)
                    .zIndex(60)
                    .allowsHitTesting(true)
            }
            .animation(.easeInOut(duration: 0.8), value: showSplash)
            .animation(.easeInOut(duration: 0.25), value: appLockService.isLocked)
            .environment(\.managedObjectContext, persistenceController.container.viewContext)
            .environment(\.aiService, OpenAIService.shared)
            .environmentObject(importService)
            .environmentObject(syncMonitor)
            .alert(
                NSLocalizedString("store.load.failed.title", comment: "Persistent store load failed title"),
                isPresented: Binding(
                    get: { storeLoadErrorMessage != nil },
                    set: { if !$0 { storeLoadErrorMessage = nil } }
                )
            ) {
                Button(NSLocalizedString("好", comment: "OK button"), role: .cancel) {}
            } message: {
                Text(
                    storeLoadErrorMessage
                        ?? NSLocalizedString("store.load.failed.message", comment: "Persistent store load failed message")
                )
            }
            .onAppear {
                showSplash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    showSplash = false
                }
                if persistenceController.isStoreLoadFailed {
                    storeLoadErrorMessage = persistenceController.storeLoadError?.localizedDescription
                        ?? NSLocalizedString("store.load.failed.message", comment: "Persistent store load failed message")
                }
                // CloudKit pull 进来新 entries 时触发一次 wordCount 回算——
                // NSPersistentCloudKitContainer 不会自动补派生字段，我们必须自己扫。
                if remoteChangeObserver == nil {
                    remoteChangeObserver = NotificationCenter.default.addObserver(
                        forName: .NSPersistentStoreRemoteChange,
                        object: persistenceController.container.persistentStoreCoordinator,
                        queue: nil
                    ) { _ in
                        // 通过 WordCountBackfillGate 串行化——CloudKit 批量 import 时
                        // remote-change 会连发多次，无 guard 时多个并发 backfill 抢
                        // store coordinator 锁，浪费 CPU + 拖慢 UI 写入。
                        Task.detached(priority: .utility) {
                            await WordCountBackfillGate.shared.runIfIdle {
                                await WordCountBackfillService.backfillIfNeeded()
                            }
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
            .onDisappear {
                if let remoteChangeObserver {
                    NotificationCenter.default.removeObserver(remoteChangeObserver)
                    self.remoteChangeObserver = nil
                }
                if let memoryWarningObserver {
                    NotificationCenter.default.removeObserver(memoryWarningObserver)
                    self.memoryWarningObserver = nil
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
            .onOpenURL { url in
                // 目前仅处理 `lumory://compose`(widget tap)。Reminder 通知点击走
                // ReminderNotificationRouter.didReceive,不会经过这里。
                LumoryURLRouter.handle(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .persistentStoreLoadFailed)) { note in
                if let error = note.userInfo?["error"] as? NSError {
                    storeLoadErrorMessage = error.localizedDescription
                } else {
                    storeLoadErrorMessage = NSLocalizedString("store.load.failed.message", comment: "Persistent store load failed message")
                }
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
            // P1-Home-6 撤销窗口兜底 — App 进 background 立即 commit pending 删除。iOS 给 ~5s
            // 后台时间,撤销 task 可能跑不完;主动 commit 把 attachment 文件清理同步触发,避免被
            // suspend 卡住留着孤儿 + 丢撤销窗口。User 重回前台时 toast 已经走完,行为一致。
            EntryDeletionUndoService.shared.commitPendingNow()
            // App lock:进 background 锁。但 inactive 也得锁(见下方 .inactive 分支)。
            AppLockService.shared.lockOnBackground()
        case .active:
            // 重新上前台：触发一次 CloudKit 状态检查,顺带把远端变更拉下来。
            // `checkCloudKitStatus()` 内部有 30s 冷却(see CloudKitSyncMonitor),频繁
            // background↔active 切换不会反复打 CloudKit;用户主动刷新走 forceSync(),
            // 那条路径绕过冷却。
            syncMonitor.checkCloudKitStatus()
            // 智能 reminder reschedule:用户可能在别的设备上写了日记(CloudKit 同步过来),
            // 或者今天 hour:minute 已过应该取消 today schedule。requestReschedule 内部
            // task cancel + replace,频繁 active/background 切换不会堆 task。
            ReminderService.shared.requestReschedule()
        case .inactive:
            // **必须在 inactive 锁,不能等 background**:iOS 在 .inactive 阶段就给 app switcher
            // 截屏。如果到 .background 才锁,multitasking 预览能看到日记 timeline。
            // 在 .inactive 立刻 set isLocked → SwiftUI 一帧渲染 LockScreenView → 系统截到锁屏画面。
            AppLockService.shared.lockOnBackground()
        @unknown default:
            break
        }
    }
}
