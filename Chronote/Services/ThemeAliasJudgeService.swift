import Foundation
import CoreData

// MARK: - ThemeAliasJudgeService
//
// 把"AI 判断 → 入待审队列"这条流水线封起来。两条入口:
//   1) 写日记后(HomeView / DiaryDetailView)调 `judgeAfterWrite(...)`
//   2) Settings 里"扫描已有主题"按钮调 `scanAllHistory(...)`
//
// 都是 @MainActor —— 与 ThemeBackfillService / EmbeddingBackfillService 同样的
// "MainActor 隔离 runningTask" 模式,避免多入口 race。

@MainActor
final class ThemeAliasJudgeService: ObservableObject {
    static let shared = ThemeAliasJudgeService()

    /// 一次 scan 的进度(供 management view 显示)。on-write 路径不暴露进度,因为只跑一次 LLM 调用。
    struct ScanProgress: Equatable {
        let isRunning: Bool
        let phase: Phase
        let suggestionsAdded: Int
        enum Phase: Equatable {
            case idle
            case fetchingInventory
            case judging
            case applying
            case done
            case failed(String)
        }
    }

    @Published private(set) var scanProgress = ScanProgress(
        isRunning: false, phase: .idle, suggestionsAdded: 0
    )

    private let persistence: PersistenceController
    private let ai: AIServiceProtocol
    private let resolver: ThemeAliasResolver

    private var scanTask: Task<Void, Never>?
    /// scanAllHistory race 兜底用的世代号。每次创建新 task 时 +1;trailing closure 比较
    /// 捕获的 myGen 与当前 scanGen,只有匹配才清 scanTask。`var newTask: Task!` 内部
    /// self-reference 模式在 Swift 6 strict mode 会触发 "mutated after capture" warning。
    private var scanGen: Int = 0

    // MARK: - Test seams (DEBUG-only)

    #if DEBUG
    /// 给 race-stale 测试读 scanGen 当前值。
    var scanGenForTesting: Int { scanGen }
    /// 给 race-stale 测试读取当前 scanTask handle。
    var scanTaskForTesting: Task<Void, Never>? { scanTask }
    /// 给测试**模拟 T2 在 T1 挂起时进入** —— 直接 bump scanGen + 替换 scanTask。
    /// 用法:T1 挂起在 ai.suspendScan 期间调,模拟"老 T1 的 trailing 闭包不该清掉新 T2 的 handle"。
    func simulateConcurrentScanStartForTesting(replacementTask: Task<Void, Never>) {
        scanGen &+= 1
        scanTask = replacementTask
    }
    #endif

    /// `judgeAfterWrite` 的软节流。每次 ai.judgeThemeAliases 都把整个 100-150 主题 inventory
    /// + 80 字符 summary snippet 上送 OpenAI proxy。无频率限制时,用户连续写日记(补昨天的、
    /// 一天 10 篇)会触发 10 次完整 inventory 上送,白付 cost + 频繁 PII 暴露。
    /// minJudgeInterval 内的二次调用直接 return(actuallyNew 短路 / inventory 短路 / AI 调用 全跳过)。
    /// 60s 是经验值:用户写完一篇后 1 分钟内通常不会写出**完全不同**的新主题,
    /// 即使 60s 内连续写 5 篇,真正新主题也会在第 6 分钟的下次 judge 一次性 cover。
    ///
    /// **P1 fix (2026-05-15 megareview)**:落 UserDefaults,App 被 jetsam kill / 用户手动 kill /
    /// 冷启动后 throttle 仍有效。原 in-memory 实现 connected sequence(午休前写一篇 → 系统 kill
    /// → 午休后写一篇)就失效,白付 OpenAI cost + 频繁 PII 上送。
    // 故意用 `UserDefaults.standard` 不是 `AppGroup.userDefaults` —— throttle 是主 App 独占的
    // 写日记节流,widget extension 不需要知道(widget 不会触发 judge)。跟 `ReminderService`
    // 的 schedule 状态用 `.standard` 一致,共同遵守"widget 不需要的数据不上 App Group"。
    // 若以后 widget extension 也要 fire judge,记得**整套**(读 + 写 + 测试 stub)切 `AppGroup.userDefaults`。
    private var lastJudgeAfterWriteAt: Date? {
        didSet {
            if let date = lastJudgeAfterWriteAt {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastJudgeAtKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastJudgeAtKey)
            }
        }
    }
    private let minJudgeInterval: TimeInterval = 60
    private static let lastJudgeAtKey = "lumory.themeAliasJudge.lastJudgeAt"

    init(
        persistence: PersistenceController = .shared,
        ai: AIServiceProtocol = OpenAIService.shared,
        resolver: ThemeAliasResolver? = nil
    ) {
        self.persistence = persistence
        self.ai = ai
        // Swift 6: 默认参数表达式是 nonisolated context,直接写 `.shared` 命中 MainActor 错误。
        // init 本身已经被 @MainActor 隔离(class 标签),内部访问 .shared 合法。
        self.resolver = resolver ?? ThemeAliasResolver.shared
        // Hydrate throttle from disk (P1 fix). `didSet` 不在 init 内 fire,这里直接读 UserDefaults。
        let storedTimestamp = UserDefaults.standard.double(forKey: Self.lastJudgeAtKey)
        if storedTimestamp > 0 {
            self.lastJudgeAfterWriteAt = Date(timeIntervalSince1970: storedTimestamp)
        }
    }

    // MARK: - On-write entry point

    /// 写完一篇日记后,把"刚抽出来的 newTags"和"用户已有库存"喂给 AI judge,
    /// 把 high/medium 匹配落入 resolver 的 pending 队列。
    /// **不阻塞**:HomeView 的 save 流程 fire-and-forget 调它,失败/空都安全。
    /// excludingEntryID 是刚保存的这篇,用来从 inventory 里去掉(避免它和自己 alias)。
    func judgeAfterWrite(
        entryID: UUID,
        newTags rawNewTags: [String]
    ) async {
        // 软节流:60s 内 second call 直接 return,避免连续写日记时反复全 inventory 上送。
        // 注意:不在 entryID 维度去重 —— 同一个 entry 重复写也只 judge 一次足够。
        if let last = lastJudgeAfterWriteAt, Date().timeIntervalSince(last) < minJudgeInterval {
            Log.info("[ThemeAliasJudge] judgeAfterWrite: 60s 内已 judge 过,跳过(entry \(entryID))", category: .ai)
            return
        }

        // 把 "已经在 group 里的别名 / 已经是 canonical" 排掉,留下真正"新出现的"
        let known = resolver.knownLowercasedTagsCovered()
        let cleanedNewTags = rawNewTags
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !known.contains(ThemeKey.make($0)) }
            .uniqued(byKey: { ThemeKey.make($0) })

        guard !cleanedNewTags.isEmpty else { return }

        // **关于 Task.isCancelled 守卫的取舍**:本函数被调用方以 fire-and-forget 模式调
        // (`Task { await judgeAfterWrite(...) }`,caller 不持 Task handle),没有外部 cancel
        // 信号注入,Task.isCancelled 永远为 false。本来 round-1 在每个 await 后都加了 isCancelled
        // 守卫,但全是 dead code 反而误导阅读者以为这函数能 cancel。删掉。
        // **stale-write 防御仍保留**:`entryStillExists` guard 是抓"用户在 judge AI call 期间删了
        // 当前 entry"的真实场景,跟 task cancellation 无关。

        // 生成 inventory:扫所有 entry 的 themes,数频次,留最近 sample。
        // 排除当前 entryID(它的 themes 就是 newTags,要避免"自己和自己 alias"的退化)。
        let inventory = await fetchInventory(excluding: entryID)

        // inventory 里如果某个 tag 的 lowercased 和 newTag 完全相同(逐字命中),
        // 说明用户以前就用过同样的 tag,根本不是"新出现"——judge 不会找出 alias,跳过。
        let inventoryKeys = Set(inventory.map { ThemeKey.make($0.tag) })
        let actuallyNew = cleanedNewTags.filter { !inventoryKeys.contains(ThemeKey.make($0)) }
        guard !actuallyNew.isEmpty else { return }

        lastJudgeAfterWriteAt = Date()
        let matches = await ai.judgeThemeAliases(
            newTags: actuallyNew,
            inventory: inventory
        )

        guard !matches.isEmpty else { return }

        // stale-write 防御:judge 期间(数秒~数十秒)用户可能已经把刚写的 entry 删了。
        // 此时仍 enqueue 会留 (entryID -> 已 tombstoned) 的 ghost suggestion,management view
        // fetch sample entry 时拿不到,显示空白卡(codex P2 #13 fix)。
        let entryStillExists = await persistence.container.performBackgroundTask { context in
            let req: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
            req.fetchLimit = 1
            return ((try? context.count(for: req)) ?? 0) > 0
        }
        guard entryStillExists else {
            Log.info("[ThemeAliasJudge] judgeAfterWrite: entry \(entryID) 已被删,跳过 enqueue", category: .ai)
            return
        }

        // 落 pending(过滤 negativePairs / 已合并 / 重复)。
        // **批量** sampleEntryIDs:一次 bg fetch 拿到所有 canonical tag 的引文 IDs,
        // 不再 N+1 sequential await(modelreturn 30 组 = 30 次 bg roundtrip → 1 次)。
        let nonNegativeMatches = matches.filter { !resolver.isNegative($0.newTag, $0.canonical) }
        let canonicalsToSample = Array(Set(nonNegativeMatches.map { $0.canonical }))
        let sampleMap = await sampleEntryIDs(forTags: canonicalsToSample, limit: 3)

        var added = 0
        for m in nonNegativeMatches {
            let suggestion = PendingSuggestion(
                newTag: m.newTag,
                canonicalGuess: m.canonical,
                confidence: PendingSuggestion.Confidence(judgeConfidence: m.confidence),
                sampleEntryIds: sampleMap[m.canonical] ?? [],
                source: .onWrite(entryID: entryID)
            )
            if resolver.enqueue(suggestion) { added += 1 }
        }

        Log.info("[ThemeAliasJudge] on-write: 新 tag \(actuallyNew.count), 入队 \(added)", category: .ai)
    }

    // MARK: - One-shot scan entry point

    @discardableResult
    func scanAllHistory() -> Task<Void, Never> {
        // 用 scanProgress.isRunning 作为 gate(而不是 scanTask 是否非 nil)——
        // 之前的版本:scanTask 完成后**没清空**,下次 if-let 仍真,反复点击退化成 noop。
        // 现在:只要 progress 不是 isRunning,就允许新建一次 scan。
        if scanProgress.isRunning, let scanTask {
            return scanTask
        }
        // superreview P1 #5 fix:
        // runScan 终止时把 scanProgress.isRunning 置 false,然后 trailing closure 清 scanTask。
        // 旧实现 trailing 是 `await MainActor.run { self?.scanTask = nil }`,在 isRunning=false
        // 后到 scanTask=nil 之间有 MainActor 重调度窗口,期间用户再点 → gate 通过 → 新 Task
        // T2 写入 scanTask → 老 Task 的 trailing 闭包执行 → **清掉 T2 的 handle**。
        // 修法:用世代号兜底 —— 闭包捕获 `let myGen`,完成后只在 `scanGen == myGen` 时清,
        // 老 task 拿到的是 stale gen → 不会误清新 task 的 handle。
        scanGen &+= 1
        let myGen = scanGen
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.runScan()
            if let self, self.scanGen == myGen {
                self.scanTask = nil
            }
        }
        scanTask = task
        return task
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if scanProgress.isRunning {
            scanProgress = ScanProgress(isRunning: false, phase: .idle, suggestionsAdded: 0)
        }
    }

    private func runScan() async {
        scanProgress = ScanProgress(isRunning: true, phase: .fetchingInventory, suggestionsAdded: 0)

        // 全部 distinct themes(不排除任何 entry)
        let inventory = await fetchInventory(excluding: nil)
        if Task.isCancelled {
            scanProgress = ScanProgress(isRunning: false, phase: .idle, suggestionsAdded: 0)
            return
        }
        guard inventory.count >= 2 else {
            scanProgress = ScanProgress(isRunning: false, phase: .done, suggestionsAdded: 0)
            return
        }

        scanProgress = ScanProgress(isRunning: true, phase: .judging, suggestionsAdded: 0)

        // 网络/后端/解析失败 → throw → 显示 .failed(reason);"真的 0 条" → return [] → .done w/ 0
        let groups: [ThemeAliasJudgeGroup]
        do {
            groups = try await ai.scanThemeAliasGroups(candidates: inventory)
        } catch {
            Log.error("[ThemeAliasJudge] scan failed: \(error)", category: .ai)
            let reason = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            scanProgress = ScanProgress(isRunning: false, phase: .failed(reason), suggestionsAdded: 0)
            return
        }
        if Task.isCancelled {
            scanProgress = ScanProgress(isRunning: false, phase: .idle, suggestionsAdded: 0)
            return
        }

        scanProgress = ScanProgress(isRunning: true, phase: .applying, suggestionsAdded: 0)

        var added = 0
        // 把 group 拆成 alias-级别的 PendingSuggestion(每个 alias 一条),用户可以单独确认/否决。
        // **codex P2 fix**:之前 inner loop 看到 cancel 只 break 内层,外层 for g in groups 继续,
        // 后续 group 的 suggestions 仍会入队。改成所有 cancel 检查点都 return。
        // **批量 sampleEntryIDs**:scan 出 30 组时之前是 30 次串行 bg fetch,现在 1 次。
        if Task.isCancelled {
            scanProgress = ScanProgress(isRunning: false, phase: .idle, suggestionsAdded: added)
            return
        }
        let canonicalsToSample = Array(Set(groups.map { $0.canonical }))
        let sampleMap = await sampleEntryIDs(forTags: canonicalsToSample, limit: 3)
        if Task.isCancelled {
            scanProgress = ScanProgress(isRunning: false, phase: .idle, suggestionsAdded: added)
            return
        }

        for g in groups {
            if Task.isCancelled {
                scanProgress = ScanProgress(isRunning: false, phase: .idle, suggestionsAdded: added)
                return
            }
            let canonical = g.canonical
            let sampleIDs = sampleMap[canonical] ?? []
            for alias in g.aliases {
                if resolver.isNegative(alias, canonical) { continue }
                let suggestion = PendingSuggestion(
                    newTag: alias,
                    canonicalGuess: canonical,
                    confidence: PendingSuggestion.Confidence(judgeConfidence: g.confidence),
                    sampleEntryIds: sampleIDs,
                    source: .scan
                )
                if resolver.enqueue(suggestion) { added += 1 }
            }
        }

        Log.info("[ThemeAliasJudge] scan: 入队 \(added)", category: .ai)
        scanProgress = ScanProgress(isRunning: false, phase: .done, suggestionsAdded: added)
    }

    // MARK: - DB helpers

    /// 拿全量 themes 直方图。`excluding` 是某 entry 的 UUID(on-write 路径排掉自己;scan 不排)。
    /// 不排"已合并的别名"——本来就要让 judge 看到 Abby 和 宝贝 共存才能判出对子。
    private func fetchInventory(excluding excludeID: UUID?) async -> [ThemeAliasJudgeCandidate] {
        await persistence.container.performBackgroundTask { context in
            let request = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
            request.resultType = .dictionaryResultType
            request.predicate = NSPredicate(format: "themes != nil AND themes != %@", "")
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
            request.propertiesToFetch = ["id", "themes", "summary"]
            request.fetchBatchSize = 200
            guard let entries = try? context.fetch(request) else { return [] }

            var counts: [String: Int] = [:]
            var samples: [String: String] = [:]
            for entry in entries {
                let entryID = (entry["id"] as? UUID)
                    ?? (entry["id"] as? NSUUID).flatMap { UUID(uuidString: $0.uuidString) }
                if let excludeID, entryID == excludeID { continue }
                let tags = DiaryEntry.parseThemesCSV(entry["themes"] as? String)
                // **隐私**:snippet 只取 `entry.summary`(已是 AI 总结后的短语,十几个字),
                // **绝不**回退到 raw `entry.text`。之前的 `summary ?? text` fallback 会把
                // 整篇日记的前 80 字符发上后端,与"alias 判别只需 tag"的设计意图相悖
                // (codex P1 #9 fix)。summary 为 nil 时这条 tag 没 snippet,模型靠
                // tag literal 名字判别已足够。
                let snippetSource = entry["summary"] as? String ?? ""
                for tag in tags where !tag.isEmpty && !InsightsEngine.isBannedTheme(tag) {
                    counts[tag, default: 0] += 1
                    if samples[tag] == nil, !snippetSource.isEmpty {
                        let trimmed = snippetSource.replacingOccurrences(of: "\n", with: " ")
                        samples[tag] = String(trimmed.prefix(80))
                    }
                }
            }
            return counts.map { tag, count in
                ThemeAliasJudgeCandidate(tag: tag, count: count, sampleSnippet: samples[tag])
            }.sorted { $0.count > $1.count }
        }
    }

    /// 给 PendingSuggestion 准备最多 N 条引文的 entry id —— management view 用 id 去 fetch 真 entry 显示卡片。
    private func sampleEntryIDs(forTag tag: String, limit: Int) async -> [UUID] {
        await persistence.container.performBackgroundTask { context in
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.predicate = NSPredicate(format: "themes CONTAINS[c] %@", tag)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
            request.fetchLimit = limit * 3   // CONTAINS 是子串匹配,可能误命中"Tokyo Japan" 找 "Tokyo",再用 themeArray 精确判断
            guard let entries = try? context.fetch(request) else { return [] }
            let exact = entries.filter { entry in
                entry.themeArray.contains { $0.lowercased() == tag.lowercased() }
            }
            return Array(exact.prefix(limit)).compactMap { $0.id }
        }
    }

    /// **批量版**:给一组 tag 一次性凑 sample IDs。给 `judgeAfterWrite` / `runScan` 替代 N+1 调用。
    /// 比 N 次独立 sampleEntryIDs 快一个数量级(N=30 group 时尤为明显:30 次 → 1 次 bg fetch)。
    ///
    /// **per-tag bucket starvation 防御**(reviewer 抓):全局 `fetchLimit` + 按日期降序的话,
    /// 一个高频 tag(如"工作")的最近 K 条会占满 fetchLimit,冷门 tag(如"妈妈")只在更老
    /// 的 entry 里出现 → 拿不到样本 → 引文卡空白。
    /// 修法:
    ///   - 用 dictionaryResultType + propertiesToFetch=["id","themes"],单条 row 极轻量
    ///   - **不设 fetchLimit**(对 dictionary 投影 + ~10K 行内存量微小)
    ///   - 边迭代边维护 "open buckets" 集合,**所有桶满即提前退出**循环
    /// 失败回 [:](所有 tag 拿到空 array),caller 跟原版语义一致。
    private func sampleEntryIDs(forTags tags: [String], limit: Int) async -> [String: [UUID]] {
        guard !tags.isEmpty else { return [:] }
        let lowercasedTags = tags.map { $0.lowercased() }
        return await persistence.container.performBackgroundTask { context in
            let subPredicates = tags.map { tag in
                NSPredicate(format: "themes CONTAINS[c] %@", tag)
            }
            // dictionaryResultType + 投影 → 不实体化 NSManagedObject,内存代价小一个数量级。
            let request = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id", "themes"]
            request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: subPredicates)
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            guard let rows = try? context.fetch(request) else {
                return Dictionary(uniqueKeysWithValues: tags.map { ($0, []) })
            }
            var buckets: [String: [UUID]] = Dictionary(uniqueKeysWithValues: tags.map { ($0, []) })
            // 跟踪还没满的桶(count < limit),所有桶满即 break 提前退出。
            var openBuckets = Set(tags)
            for row in rows {
                if openBuckets.isEmpty { break }
                guard let id = row["id"] as? UUID,
                      let csv = row["themes"] as? String, !csv.isEmpty else { continue }
                let entryTags = DiaryEntry.parseThemesCSV(csv).map { $0.lowercased() }
                for (idx, lowerTag) in lowercasedTags.enumerated() where entryTags.contains(lowerTag) {
                    let originalTag = tags[idx]
                    let currentCount = buckets[originalTag, default: []].count
                    if currentCount < limit {
                        buckets[originalTag, default: []].append(id)
                        if currentCount + 1 >= limit {
                            openBuckets.remove(originalTag)
                        }
                    }
                }
            }
            return buckets
        }
    }
}

// MARK: - Helpers

private extension PendingSuggestion.Confidence {
    init(judgeConfidence c: ThemeAliasJudgeMatch.Confidence) {
        switch c {
        case .high: self = .high
        case .medium: self = .medium
        }
    }

    init(judgeConfidence c: ThemeAliasJudgeGroup.Confidence) {
        switch c {
        case .high: self = .high
        case .medium: self = .medium
        }
    }
}

private extension Array {
    func uniqued<Key: Hashable>(byKey key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}
