import Foundation
import CoreData
#if canImport(WidgetKit)
import WidgetKit
#endif

/// 把 CoreData 状态投影成 widget 可读的 JSON snapshot,并通知 WidgetKit reload。
///
/// **`actor` 而非 `@MainActor`**: 主要工作是 debounce + CoreData 后台 fetch + JSON 文件 IO,
/// 不需要主线程隔离;observer / Settings toggle 端用 `Task { await ... }` hop 进 actor。
///
/// 触发入口都汇合到 `requestRefresh(persistence:bypassDebounce:)`:
/// - `PersistenceController.init` 挂的 `NSManagedObjectContextDidSave` / `NSPersistentStoreRemoteChange`
///   observer(本进程 save + CloudKit pull)
/// - `ChronoteApp.init` 末尾的启动一次
/// - Settings 翻 `lumory.widget.showSnippets` toggle
/// - bulk-delete 路径(call `clear()`,见"五件套")
actor WidgetSnapshotService {
    static let shared = WidgetSnapshotService()

    /// privacy-first toggle key。default false。`UserDefaults` 反向 sentinel 不需要 ——
    /// widget 是新功能,没有"老用户已激活"的 legacy 行为要保护。
    static let showSnippetsDefaultsKey = "lumory.widget.showSnippets"

    private static let debounceInterval: UInt64 = 250 * 1_000_000 // 250ms

    private var pendingTask: Task<Void, Never>?

    private init() {}

    /// 请求一次 snapshot 重写。250ms debounce —— 短时间内多次 save(批量 import / CloudKit
    /// 拉一批进来)合并成一次磁盘写。`bypassDebounce: true` 立即跑 + await 完成,给 toggle off
    /// 这种隐私敏感路径用。
    ///
    /// 入口先 guard `persistence.isInMemory == false` —— 单测 / screenshot 模式 store 是临时数据,
    /// 写到真实 widget snapshot 反而会污染主屏。
    func requestRefresh(persistence: PersistenceController, bypassDebounce: Bool = false) async {
        guard !persistence.isInMemory else { return }

        if bypassDebounce {
            pendingTask?.cancel()
            pendingTask = nil
            await performRefresh(persistence: persistence)
            return
        }

        pendingTask?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceInterval)
            guard !Task.isCancelled, let self else { return }
            await self.performRefresh(persistence: persistence)
        }
        pendingTask = task
    }

    /// 用 empty snapshot 覆盖盘上文件,并 reload widget。
    /// "五件套"删除路径调用,保证 widget 不展示已删数据的 stale snapshot。
    func clear() {
        pendingTask?.cancel()
        pendingTask = nil
        WidgetSnapshotStore.clear()
        reloadWidgets()
    }

    // MARK: - Private

    private func performRefresh(persistence: PersistenceController) async {
        let showSnippets = UserDefaults.standard.bool(forKey: Self.showSnippetsDefaultsKey)
        let snapshot = await fetchSnapshot(persistence: persistence, showSnippets: showSnippets)
        do {
            try WidgetSnapshotStore.write(snapshot)
            reloadWidgets()
        } catch {
            Log.error("[WidgetSnapshotService] write failed: \(error)", category: .persistence)
        }
    }

    /// CoreData 后台 fetch + 计算。返值类型 (`WidgetSnapshot`) 是 `Sendable`,跨 actor 安全。
    /// 不在 main / 不在 viewContext 上跑。
    private func fetchSnapshot(persistence: PersistenceController, showSnippets: Bool) async -> WidgetSnapshot {
        // **外部预算 today** —— 跟 InsightsEngine.writingStats 同 idiom,锁死时区/DST 边界秒。
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        return await persistence.container.performBackgroundTask { context -> WidgetSnapshot in
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
            request.returnsObjectsAsFaults = false
            // 全字段 fetch —— totalWords 累加 + 唯一日列表 + 最近 5 条 displayText 都要。
            // DiaryEntry 表条目数量上限实际就是用户写过的日记篇数(≤几千),全 fetch 没问题。

            guard let entries = try? context.fetch(request), !entries.isEmpty else {
                return .empty()
            }

            var totalWords = 0
            var moodSum = 0.0
            var uniqueDaysDesc: [Date] = []
            uniqueDaysDesc.reserveCapacity(entries.count)
            for entry in entries {
                totalWords += Int(entry.wordCount)
                moodSum += entry.moodValue
                if let date = entry.date {
                    let day = calendar.startOfDay(for: date)
                    if uniqueDaysDesc.last != day { uniqueDaysDesc.append(day) }
                }
            }
            _ = moodSum // suppress warning;预留给 future avg field

            let (currentStreak, longestStreak) = InsightsEngine.computeStreaks(
                uniqueDaysDesc: uniqueDaysDesc,
                today: today,
                calendar: calendar
            )

            let lastEntry = entries.first
            let lastEntryDate = lastEntry?.date
            let lastEntryMood = lastEntry?.moodValue
            let lastEntryDisplayText: String? = showSnippets ? lastEntry?.displayText : nil

            let recent: [WidgetSnapshot.Snippet] = entries.prefix(5).map { e in
                WidgetSnapshot.Snippet(
                    id: e.id ?? UUID(),
                    date: e.date ?? Date(),
                    moodValue: e.moodValue,
                    displayText: showSnippets ? e.displayText : nil
                )
            }

            return WidgetSnapshot(
                generatedAt: Date(),
                totalEntries: entries.count,
                totalWords: totalWords,
                currentStreak: currentStreak,
                longestStreak: longestStreak,
                lastEntryDate: lastEntryDate,
                lastEntryMood: lastEntryMood,
                lastEntryDisplayText: lastEntryDisplayText,
                recent: recent
            )
        }
    }

    private nonisolated func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: LumoryWidgetKind.quickWrite)
        #endif
    }
}

// MARK: - Privacy scrub helper(toggle off 路径)

extension WidgetSnapshotService {
    /// Settings 把 `showSnippets` 从 on 翻到 off 时调。
    /// **同步**先写一份"metadata-only"snapshot(displayText 全空),立即让磁盘上没残留正文 ——
    /// 防 250ms debounce 中途进程被杀。然后再异步 refresh 把 metadata 重算。
    nonisolated func scrubSnippetsImmediately() {
        if let stale = WidgetSnapshotStore.read() {
            var stripped = stale
            stripped.lastEntryDisplayText = nil
            stripped.recent = stale.recent.map {
                WidgetSnapshot.Snippet(id: $0.id, date: $0.date, moodValue: $0.moodValue, displayText: nil)
            }
            try? WidgetSnapshotStore.write(stripped)
        }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: LumoryWidgetKind.quickWrite)
        #endif
    }
}
