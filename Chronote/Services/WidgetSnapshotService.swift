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
/// - `PersistenceController.init` 挂的 `NSManagedObjectContextDidSave` /
///   `NSPersistentStoreRemoteChange` observer(本进程 save + CloudKit pull)
/// - `ChronoteApp.init` 末尾的启动一次
/// - bulk-delete 路径(call `clear()`,见"五件套")
///
/// V2 schema:streak / longestStreak / lastEntryMood / prompt。**不再有日记正文 / mood 条带**
/// (V1 / 中间带 recentDays 形态都已退役),fetch 逻辑因此简化到只算 streak + 取 lastEntry。
actor WidgetSnapshotService {
    static let shared = WidgetSnapshotService()

    private static let debounceInterval: UInt64 = 250 * 1_000_000 // 250ms

    private var pendingTask: Task<Void, Never>?

    /// **世代号** —— 给 `performRefresh` 在 await 间隙后辨认"我还是不是当前应该写盘的那个"。
    /// 每次 `requestRefresh` 起新轮次 / 每次 `clear()` 都 `&+=1`。`performRefresh` 在 fetch
    /// 之后 / `WidgetSnapshotStore.write` 之前比对 captured gen vs `generation`,不一致就跳过 write。
    /// 这条防的是:`clear()` 已经把 empty snapshot 写盘 + reload,但更早起的某次 refresh task 还在
    /// `currentPrompt()` / `fetchSnapshot` await 里挂着,`pendingTask?.cancel()` 不能传播到那里
    /// (cancel 只杀 sleep,不杀已 enter actor body 的方法),resume 后会把 stale 数据写回来。
    private var generation: Int = 0

    /// **Content digest dedup** —— 上次 write 的内容指纹(streak / lastEntry / prompt 等用户可见字段)。
    /// 一键重建索引 / EmbeddingBackfillService / ThemeBackfillService 节奏 ~900ms 一次 save,
    /// 250ms debounce 合并不掉,observer 会触发 N 次 fetch + N 次 `WidgetCenter.reloadTimelines`,
    /// 即便 widget 显示**完全没变**(只是 embedding/themes 字段更新)。digest 命中 → 跳过 write
    /// + reload,fetch 仍然跑(dict-fetch 几 ms)但不让 widget 系统反复 throttle 调度。
    /// `clear()` 写入 empty 后把 digest 同步成 empty 的指纹,防"清完后第一次有效 refresh 因为
    /// 指纹未更新被错误跳过"。
    private var lastWrittenDigest: Int?

    /// **Per-day prompt cache** —— 同一天内所有 refresh 共用一条 prompt,跨天 / 进程重启才换。
    ///
    /// 不加这层 cache 会怎样:`PromptSuggestionEngine.randomHomePlaceholder()` 每次返回不同条目;
    /// 而冷启动 + CloudKit pull 暴风期会让 `requestRefresh` 在几秒内被触发数次,每次写新 snapshot
    /// + reload widget,用户加 widget 时眼睁睁看着 headline 连续切换 3-5 次才稳定 —— 像故障。
    /// 缓存只存"成功 pick 到的"字符串(nil 不 cache),让 PromptSuggestionEngine 后续 AI bundle
    /// ready 后第一次成功取值能进 cache。
    private var cachedPrompt: String?
    private var cachedPromptDay: Date?

    private init() {}

    /// 请求一次 snapshot 重写。250ms debounce —— 短时间内多次 save(批量 import / CloudKit
    /// 拉一批进来)合并成一次磁盘写。`bypassDebounce: true` 立即跑 + await 完成。
    ///
    /// 入口先 guard `persistence.isInMemory == false` —— 单测 / screenshot 模式 store 是临时数据,
    /// 写到真实 widget snapshot 反而会污染主屏。
    func requestRefresh(persistence: PersistenceController, bypassDebounce: Bool = false) async {
        guard !persistence.isInMemory else { return }
        // **stores 还没 load 完时跳过** —— 否则 `context.fetch` 会抛错或返空,落到 `.empty()` 兜底,
        // 把磁盘上有效 snapshot 覆盖成 0/0/0。冷启动时 `ChronoteApp.init` 的 `Task.detached` 会先 fire 一次,
        // 此刻 store 大概率没 load 完;`PersistenceController.loadPersistentStores` 成功 callback 内
        // 会再 schedule 一次 refresh —— 那时再走真正的 fetch。
        guard !persistence.container.persistentStoreCoordinator.persistentStores.isEmpty else { return }

        if bypassDebounce {
            pendingTask?.cancel()
            pendingTask = nil
            generation &+= 1
            let myGen = generation
            await performRefresh(persistence: persistence, gen: myGen)
            return
        }

        pendingTask?.cancel()
        generation &+= 1
        let myGen = generation
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceInterval)
            guard !Task.isCancelled, let self else { return }
            await self.performRefresh(persistence: persistence, gen: myGen)
        }
        pendingTask = task
    }

    /// 用 empty snapshot 覆盖盘上文件,并 reload widget。
    /// "五件套"删除路径调用,保证 widget 不展示已删数据的 stale snapshot。
    /// 同时清 prompt cache —— 删完后 PromptSuggestionEngine 自己也会 clearCache(五件套另一员),
    /// 我们不留 stale 引用让下次 refresh 能拿到 nil → fallback CTA。
    /// **`generation &+= 1`** 让任何已经在 `performRefresh` await 里挂着的 in-flight task
    /// 在 resume 后 write 之前发现 gen 过期,跳过 write,不会用 stale 数据覆盖刚写的 empty。
    func clear() {
        pendingTask?.cancel()
        pendingTask = nil
        generation &+= 1
        cachedPrompt = nil
        cachedPromptDay = nil
        WidgetSnapshotStore.clear()
        // 同步指纹到 empty —— 避免"清完后立刻 fetch 拿到的也是 empty"被 dedup 错误跳过(其实有道理跳过,
        // 但这里语义是"主动 reset",跟 user-driven 全删一样,显式更新指纹比依赖巧合好读)。
        lastWrittenDigest = Self.contentDigest(.empty())
        reloadWidgets()
    }

    // MARK: - Private

    private func performRefresh(persistence: PersistenceController, gen: Int) async {
        // Prompt:走 per-day cache(见 `currentPrompt()`),保证 widget headline 不在
        // 多次 refresh 之间抖动。
        //
        // -------------------------------------------------------------------------
        // **🔒 隐私决定 / Code review 不要再提:**
        // 不要把 prompt 拉藏到 `useContextualBody` 或新 toggle 后面 —— widget 的核心价值就是
        // 在主屏给一句"对你来说有意义的事",藏到 toggle 后 + 默认 off 等于砍掉功能。
        // 已评估过"主题词可能含人名 / 锁屏可见"的隐私 axis,产品决策**故意不 gate**,接受这个面。
        // 用户想匿名化主屏可以系统级关锁屏 always-on,或者关 widget 整个不用。
        // -------------------------------------------------------------------------
        let prompt = await currentPrompt()
        // 世代号 gate:每个 await 之后都要再确认一遍 gen 还没被 clear() / 新 requestRefresh bump 过,
        // 否则我们就是个"上一辈"task,write 会用 stale 数据覆盖最新 snapshot。
        guard gen == generation else { return }
        let snapshot = await fetchSnapshot(persistence: persistence, prompt: prompt)
        guard gen == generation else { return }
        // Content digest dedup —— 内容跟上次 write 一致(典型:backfill 改 embedding/themes 但
        // streak/lastEntry/prompt 都没变)就跳过 write + reload,避免一键重建期间 N 次空刷。
        let digest = Self.contentDigest(snapshot)
        guard digest != lastWrittenDigest else { return }
        do {
            try WidgetSnapshotStore.write(snapshot)
            lastWrittenDigest = digest
            reloadWidgets()
        } catch {
            Log.error("[WidgetSnapshotService] write failed: \(error)", category: .persistence)
        }
    }

    /// 用户可见字段的指纹。**故意不含 `generatedAt`** —— 那是 wall-clock 时间戳,每次 fetch 都不一样,
    /// 含进去会让 dedup 永远 miss。
    private static func contentDigest(_ snap: WidgetSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(snap.schemaVersion)
        hasher.combine(snap.currentStreak)
        hasher.combine(snap.longestStreak)
        hasher.combine(snap.lastEntryDate)
        hasher.combine(snap.lastEntryMood)
        hasher.combine(snap.prompt)
        return hasher.finalize()
    }

    /// Per-day prompt 缓存的查取入口。同一天命中 cache,跨天或第一次 miss 才 hop MainActor 拿新值。
    /// nil 不进 cache —— PromptSuggestionEngine 还没 ready 时下次能再试。
    private func currentPrompt() async -> String? {
        let today = Calendar.current.startOfDay(for: Date())
        if let cached = cachedPrompt, cachedPromptDay == today {
            return cached
        }
        let fresh = await MainActor.run {
            PromptSuggestionEngine.shared.randomHomePlaceholder()
        }
        if let fresh {
            cachedPrompt = fresh
            cachedPromptDay = today
        }
        return fresh
    }

    /// CoreData 后台 fetch + 计算。返值类型 (`WidgetSnapshot`) 是 `Sendable`,跨 actor 安全。
    /// 不在 main / 不在 viewContext 上跑。
    private func fetchSnapshot(persistence: PersistenceController, prompt: String?) async -> WidgetSnapshot {
        // 外部预算时间锚点 —— 跟 InsightsEngine.writingStats 同 idiom,锁死时区/DST 边界秒。
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)

        return await persistence.container.performBackgroundTask { context -> WidgetSnapshot in
            // **Dictionary fetch**(`NSDictionaryResultType` + `propertiesToFetch=[date, moodValue]`)——
            // 只取两列原始值,**不实例化** `NSManagedObject`,所以 `embedding`(Float32 数组,KB/行)
            // 和 `imagesData`(UIImage 归档,可达 MB/行)完全不会进 RAM。每行 ~16 字节,数千 entry 也轻松。
            //
            // **不设 fetchLimit** —— streak / longestStreak 必须扫全量历史。曾经设 400 行上限,
            // 重度用户(每天多条 entry)或 longest streak 在更老 entries 里时会低估,跟 Insights 不一致。
            // dict fetch 把单行成本压到极小,全量扫安全。
            let request = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["date", "moodValue"]
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            // **`date <= now` 守卫**:CK 同步把另一台时钟跑前的设备写的 entry 拉过来 / 用户手动导入
            // 一篇带未来日期的 entry 时,如果不过滤,sort desc 会让那条未来 entry 排第一行,被当成
            // `lastEntryDate` / `lastEntryMood` 写进 snapshot。`WidgetTodayContext.compute` 看到
            // lastEntryDate 不是今天 → `wroteToday = false` → widget 显示"记录今天",今天的真实
            // entry / mood 全被这条幽灵未来 entry 顶掉。同 idiom 已用在 reminder 调度中。
            request.predicate = NSPredicate(format: "date <= %@", now as NSDate)

            guard let dicts = try? context.fetch(request), !dicts.isEmpty else {
                // 没数据(全新装机 / 用户全删后)—— 透传 prompt;widget headline 仍能渲染 prompt
                // 或 fallback "记录今天" CTA,不至于完全空白。
                return WidgetSnapshot(
                    generatedAt: Date(),
                    currentStreak: 0,
                    longestStreak: 0,
                    lastEntryDate: nil,
                    lastEntryMood: nil,
                    prompt: prompt
                )
            }

            // 收集 unique day list 给 streak 算法。dicts 已按 date 降序,相邻同日跳过(去重)。
            var uniqueDaysDesc: [Date] = []
            uniqueDaysDesc.reserveCapacity(min(dicts.count, 4096))
            for dict in dicts {
                guard let date = dict["date"] as? Date else { continue }
                let day = calendar.startOfDay(for: date)
                if uniqueDaysDesc.last != day { uniqueDaysDesc.append(day) }
            }

            let (currentStreak, longestStreak) = InsightsEngine.computeStreaks(
                uniqueDaysDesc: uniqueDaysDesc,
                today: today,
                calendar: calendar
            )

            // dicts 已按 date 降序,首行就是最新 entry 的 (date, moodValue)。
            let firstDict = dicts.first
            let lastEntryDate = firstDict?["date"] as? Date
            let lastEntryMood = firstDict?["moodValue"] as? Double
            return WidgetSnapshot(
                generatedAt: Date(),
                currentStreak: currentStreak,
                longestStreak: longestStreak,
                lastEntryDate: lastEntryDate,
                lastEntryMood: lastEntryMood,
                prompt: prompt
            )
        }
    }

    private nonisolated func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: LumoryWidgetKind.quickWrite)
        #endif
    }
}
