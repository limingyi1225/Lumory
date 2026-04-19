import Foundation
import CoreData

/// 一次性把所有历史 DiaryEntry 的 `wordCount` 算一遍。
///
/// 背景：`wordCount` 是后加进 Core Data 模型的属性（default = 0）。**升级用户的老日记 `wordCount`
/// 全部是 0**，Insights 的累计字数 = 0、heatmap 强度全灭，视觉上"好像没写过日记"。
/// NSPersistentCloudKitContainer 不会帮我们回算这种派生字段——必须我们自己扫。
///
/// 策略：每次 App 启动都扫一遍 `wordCount == 0 AND text != nil`。
/// 没有 flag——因为 CloudKit pull 进来的老 entries 可能在任意时间点抵达本地；一旦抵达，我们
/// 仍然需要算字数。走 fetchCount 先判空，没 pending 就立刻返回，代价只有一次 SQL count。
enum WordCountBackfillService {

    /// 在 App 启动后 + 每次收到 `NSPersistentStoreRemoteChange` 时调。
    /// 走后台 context，不阻塞主线程；fetchCount 为 0 时立即返回。
    static func backfillIfNeeded() async {
        let processed = await runBackfill()
        if processed > 0 {
            Log.info("[WordCountBackfill] 本轮处理 \(processed) 条 wordCount=0 的记录", category: .persistence)
        }
    }

    /// 一键重建里会调——等价于 `backfillIfNeeded`（内部已经是幂等的）。
    @discardableResult
    static func forceBackfill() async -> Int {
        await runBackfill()
    }

    private static func runBackfill() async -> Int {
        let container = PersistenceController.shared.container
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<DiaryEntry>(entityName: "DiaryEntry")
                // 仅拉 wordCount == 0 且 text 非空 / 非 nil 的——已经算过的不动，避免浪费。
                // 这样哪怕用户日记里 *真的* 就 0 字（比如只有图片或音频），我们也不误报。
                // 不用 predicate 过滤 text，因为 Core Data text IS NULL / EMPTY 在 SQLite 下要写两段。
                request.predicate = NSPredicate(format: "wordCount == 0")

                var processed = 0
                do {
                    let entries = try context.fetch(request)
                    for entry in entries {
                        let raw = entry.text ?? ""
                        let count = DiaryEntry.countWords(in: raw)
                        if count > 0 {
                            entry.wordCount = Int32(count)
                            processed += 1
                        }
                    }
                    if context.hasChanges {
                        try context.save()
                    }
                } catch {
                    Log.error("[WordCountBackfill] 失败：\(error)", category: .persistence)
                }
                continuation.resume(returning: processed)
            }
        }
    }
}
