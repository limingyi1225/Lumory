import Foundation
import CoreData
import Combine

// MARK: - EmbeddingBackfillService
//
// 给 Phase 0 新增的 `DiaryEntry.embedding` 字段做一次性回填。
// Lumory 不是大众工具，用户可能存量几百条日记；我们一次只跑 10 条、间隔 500ms，
// 控速并可随时暂停，避免触发 OpenAI rate limit 或把手机 CPU 打满。
//
// 用法：
//   Task { await EmbeddingBackfillService.shared.backfillAll() }
//   service.progress.sink { progress in ... }   // 可订阅
//
// 幂等性：每次启动先查一遍还剩多少条 embedding 为 nil 的条目；已有 embedding 的不重算。

@available(iOS 15.0, macOS 12.0, *)
final class EmbeddingBackfillService: ObservableObject {
    static let shared = EmbeddingBackfillService()

    // MARK: Public state

    struct Progress: Equatable {
        let processed: Int
        let total: Int
        let failed: Int
        let isRunning: Bool
        var fraction: Double {
            total == 0 ? 1 : Double(processed) / Double(total)
        }
    }

    @Published private(set) var progress = Progress(processed: 0, total: 0, failed: 0, isRunning: false)

    // MARK: Deps

    private let persistence: PersistenceController
    private let ai: AIServiceProtocol
    private let batchSize: Int
    private let throttleNanos: UInt64

    // runningTask 加 @MainActor 隔离：所有 start / cancel 入口都要 await 到 MainActor 才能读写，
    // 从而保证 Settings「一键重建」按钮、自动路径、未来的 auto-backfill 任何多入口都在同一条线上排队。
    // 以前是裸 `var`，不 actor-safe，多入口 race 会让两份 run() 同时跑、progress 串号。
    @MainActor private var runningTask: Task<Void, Never>?
    @MainActor private var runningRunID: UUID?
    @MainActor private var pendingCache: (value: Int, date: Date)?

    init(
        persistence: PersistenceController = .shared,
        ai: AIServiceProtocol = OpenAIService.shared,
        // 原来 batch=10, throttle=500ms → peak ~1200 req/min，把服务端 embeddings limit 300/min
        // 撞死。改 batch=3, throttle=900ms → peak ~200 req/min，留 50% headroom。
        // 500 条日记跑完约 2.5 分钟。
        batchSize: Int = 3,
        throttleMs: UInt64 = 900
    ) {
        self.persistence = persistence
        self.ai = ai
        self.batchSize = batchSize
        self.throttleNanos = throttleMs * 1_000_000
    }

    // MARK: Public API

    /// 全量回填缺失 embedding 的条目。再次调用时若已在跑则忽略。
    @MainActor
    @discardableResult
    func backfillAll() async -> Progress {
        if let runningTask, !runningTask.isCancelled {
            Log.info("[EmbeddingBackfill] 已在运行，忽略重复调用", category: .migration)
            return progress
        }

        pendingCache = nil
        let runID = UUID()
        // [weak self]：和 ThemeBackfillService 同款——避免 Task 强捕 singleton 的 AI 客户端和缓存
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.run(runID: runID)
        }
        runningTask = task
        runningRunID = runID
        await task.value
        if runningRunID == runID {
            runningTask = nil
            runningRunID = nil
            pendingCache = nil
        }
        return progress
    }

    @MainActor
    func cancel() {
        runningTask?.cancel()
        runningTask = nil
        runningRunID = nil
        pendingCache = nil
    }

    // MARK: Core loop

    private func run(runID: UUID) async {
        let missingIDs = await fetchMissingObjectIDs()
        Log.info("[EmbeddingBackfill] 待回填条目数: \(missingIDs.count)", category: .migration)

        await publish(Progress(processed: 0, total: missingIDs.count, failed: 0, isRunning: true), runID: runID)

        guard !missingIDs.isEmpty else {
            await publish(Progress(processed: 0, total: 0, failed: 0, isRunning: false), runID: runID)
            return
        }

        var processed = 0
        var failed = 0

        for batch in missingIDs.chunked(into: batchSize) {
            if Task.isCancelled { break }
            for objectID in batch {
                if Task.isCancelled { break }
                let ok = await processOne(objectID: objectID)
                if ok { processed += 1 } else { failed += 1 }
                await publish(Progress(processed: processed, total: missingIDs.count, failed: failed, isRunning: true), runID: runID)
            }
            // 喘口气，避免 OpenAI 限流
            try? await Task.sleep(nanoseconds: throttleNanos)
        }

        Log.info("[EmbeddingBackfill] 完成: 成功 \(processed) / 失败 \(failed)", category: .migration)
        await publish(Progress(processed: processed, total: missingIDs.count, failed: failed, isRunning: false), runID: runID)
    }

    // MARK: Public count

    /// 当前缺 embedding 的条目数。用 count 而不是 fetch + count,扫一遍主键索引就出来,
    /// 不会把 NSManagedObject 实例化进 context,Settings 页面随手调安全。
    @MainActor
    func pendingCount() async -> Int {
        if let pendingCache, Date().timeIntervalSince(pendingCache.date) < 5 {
            return pendingCache.value
        }
        let count = await persistence.container.performBackgroundTask { context -> Int in
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.predicate = NSPredicate(format: "embedding == nil AND text != nil AND text != %@", "")
            return (try? context.count(for: request)) ?? 0
        }
        pendingCache = (count, Date())
        return count
    }

    // MARK: DB helpers

    private func fetchMissingObjectIDs() async -> [NSManagedObjectID] {
        await persistence.container.performBackgroundTask { context -> [NSManagedObjectID] in
            let request = NSFetchRequest<NSManagedObjectID>(entityName: "DiaryEntry")
            // 只挑 text 非空且 embedding 为 nil 的
            request.predicate = NSPredicate(format: "embedding == nil AND text != nil AND text != %@", "")
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
            request.resultType = .managedObjectIDResultType
            request.fetchBatchSize = 200
            return (try? context.fetch(request)) ?? []
        }
    }

    /// 处理单条：读取 text → 请求 embedding → 写回 Core Data。
    private func processOne(objectID: NSManagedObjectID) async -> Bool {
        // 先读取 text（需要在 managed context 上）
        let text: String? = await persistence.container.performBackgroundTask { context in
            guard let entry = try? context.existingObject(with: objectID) as? DiaryEntry else { return nil }
            let text = entry.text ?? ""
            return text.isEmpty ? nil : text
        }
        guard let text else { return false }

        // 请求 embedding（网络调用，不锁 Core Data）
        let vector = await ai.embed(text: text)
        guard let vector else {
            Log.error("[EmbeddingBackfill] embed 失败: \(objectID)", category: .migration)
            return false
        }

        // 写回前对比当前文本是否还和请求 embedding 时的快照相同，防止覆盖用户新写
        return await persistence.container.performBackgroundTask { context in
            guard let entry = try? context.existingObject(with: objectID) as? DiaryEntry else { return false }
            if (entry.text ?? "") != text {
                Log.info("[EmbeddingBackfill] 文本已在网络调用期间变化，丢弃 stale embedding", category: .migration)
                return true
            }
            entry.setEmbedding(vector)
            if entry.wordCount == 0 {
                entry.recomputeWordCount()
            }
            do {
                try context.save()
                return true
            } catch {
                Log.error("[EmbeddingBackfill] save 失败: \(error)", category: .migration)
                return false
            }
        }
    }

    @MainActor
    private func publish(_ value: Progress, runID: UUID) {
        guard runningRunID == runID else { return }
        self.progress = value
    }
}

// MARK: - Array chunk helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
