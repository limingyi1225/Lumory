import Foundation
import CoreData
import Combine

// MARK: - ThemeBackfillService
//
// 旧的 extractThemes prompt 把"情绪/心情"等元描述塞进主题 CSV，聚合时噪音大。
// 新 prompt 改掉后，历史日记的主题还是老的（AI 只在写入瞬间跑一次）。
// 这个 service 给用户一个"刷新主题"按钮，把存量日记全跑一遍新 prompt，
// 修成干净数据。
//
// 设计思路与 EmbeddingBackfillService 对齐：
//  - 后台 batch 处理（默认 5 条一批），每批间隔 800ms 避免 rate limit
//  - 幂等：根据 entry.text 重新抽，旧 themes 被覆盖
//  - 可取消；失败不阻塞下一条
//
// 范围策略：
//  - 默认只处理有明显问题的：themes 为空、或命中 bannedTheme
//  - "强制全量" 模式：全部重跑（用户想彻底重算时）

@available(iOS 15.0, macOS 12.0, *)
final class ThemeBackfillService: ObservableObject {

    static let shared = ThemeBackfillService()

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

    private let persistence: PersistenceController
    private let ai: AIServiceProtocol
    private let batchSize: Int
    private let throttleNanos: UInt64

    private var runningTask: Task<Void, Never>?

    init(
        persistence: PersistenceController = .shared,
        ai: AIServiceProtocol = OpenAIService(apiKey: ""),
        // 原来 batch=5, throttle=800ms → peak ~375 req/min，会撞服务端 120/min 的 chat limit。
        // 现改 batch=2, throttle=1400ms → peak ~85 req/min，正常运行时无 429 风险。
        // 500 条日记跑完约 6 分钟——比原来慢，但换来"重建不会半拉"。
        batchSize: Int = 2,
        throttleMs: UInt64 = 1400
    ) {
        self.persistence = persistence
        self.ai = ai
        self.batchSize = batchSize
        self.throttleNanos = throttleMs * 1_000_000
    }

    // MARK: Public API

    /// 回填有问题的条目：themes 为空 或 含有被禁用元描述（比如"情绪"）。
    @discardableResult
    func backfillProblems() async -> Progress {
        await run(mode: .problemsOnly)
    }

    /// 全量重新抽取所有条目的主题。用户主动选择时再用，贵。
    @discardableResult
    func backfillAll() async -> Progress {
        await run(mode: .all)
    }

    func cancel() {
        runningTask?.cancel()
        runningTask = nil
    }

    // MARK: Core loop

    private enum Mode { case problemsOnly, all }

    private func run(mode: Mode) async -> Progress {
        if runningTask != nil {
            Log.info("[ThemeBackfill] 已在运行，忽略重复调用", category: .migration)
            return progress
        }

        // [weak self]：service 是 `shared` singleton 正常不会释放；但如果未来被注入/换掉，
        // Task 对 self 的强引用会把 service + 它持有的 AI 客户端 + 一整批 objectIDs 拖住。
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.execute(mode: mode)
        }
        runningTask = task
        await task.value
        runningTask = nil
        return progress
    }

    private func execute(mode: Mode) async {
        let objectIDs = await fetchCandidates(mode: mode)
        Log.info("[ThemeBackfill] 待处理条目数: \(objectIDs.count) (mode=\(mode))", category: .migration)

        await publish(Progress(processed: 0, total: objectIDs.count, failed: 0, isRunning: true))

        guard !objectIDs.isEmpty else {
            await publish(Progress(processed: 0, total: 0, failed: 0, isRunning: false))
            return
        }

        var processed = 0
        var failed = 0

        for batch in objectIDs.chunked(into: batchSize) {
            if Task.isCancelled { break }
            for objectID in batch {
                if Task.isCancelled { break }
                let ok = await processOne(objectID: objectID)
                processed += 1
                if !ok { failed += 1 }
                await publish(Progress(processed: processed, total: objectIDs.count, failed: failed, isRunning: true))
            }
            try? await Task.sleep(nanoseconds: throttleNanos)
        }

        let succeeded = max(0, processed - failed)
        Log.info("[ThemeBackfill] 完成: 成功 \(succeeded) / 失败 \(failed)", category: .migration)
        await publish(Progress(processed: processed, total: objectIDs.count, failed: failed, isRunning: false))
    }

    // MARK: DB helpers

    private func fetchCandidates(mode: Mode) async -> [NSManagedObjectID] {
        await persistence.container.performBackgroundTask { context in
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.predicate = NSPredicate(format: "text != nil AND text != %@", "")
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
            guard let entries = try? context.fetch(request) else { return [] }

            switch mode {
            case .all:
                return entries.map { $0.objectID }
            case .problemsOnly:
                return entries.compactMap { entry -> NSManagedObjectID? in
                    let themes = entry.themeArray
                    if themes.isEmpty { return entry.objectID }
                    // 任何一个命中 banned 词就视为需要清理
                    if themes.contains(where: { InsightsEngine.isBannedTheme($0) }) {
                        return entry.objectID
                    }
                    return nil
                }
            }
        }
    }

    private func processOne(objectID: NSManagedObjectID) async -> Bool {
        // **防覆盖写**：拿一份"读取时的文本"快照随网络走一趟，写回前对比当前文本——
        // 以前读写分两个 performBackgroundTask，期间用户可能保存了新版本，慢的那条 extractThemes
        // 回来后把旧文本的 themes 写回去，covers new themes。对比快照即可丢弃 stale 结果。
        let text: String? = await persistence.container.performBackgroundTask { context in
            guard let entry = try? context.existingObject(with: objectID) as? DiaryEntry else { return nil }
            let text = entry.text ?? ""
            return text.isEmpty ? nil : text
        }
        guard let text else { return false }

        let themes = await ai.extractThemes(text: text)
        // 空数组是合法结果（纯抒情文字），视为成功写入。

        return await persistence.container.performBackgroundTask { context in
            guard let entry = try? context.existingObject(with: objectID) as? DiaryEntry else { return false }
            // Stale guard：如果 entry.text 已变，当前 themes 结果是基于旧文本，丢弃
            if (entry.text ?? "") != text {
                Log.info("[ThemeBackfill] 文本已在网络调用期间变化，丢弃 stale themes 结果", category: .migration)
                return true // 当做"成功"——下次 sweep 会重新处理
            }
            entry.setThemes(themes)
            do {
                try context.save()
                return true
            } catch {
                Log.error("[ThemeBackfill] save 失败: \(error)", category: .migration)
                return false
            }
        }
    }

    @MainActor
    private func publish(_ value: Progress) {
        self.progress = value
    }
}

// MARK: - Chunk helper (与 EmbeddingBackfillService 的保持独立以免跨文件隐藏耦合)

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
