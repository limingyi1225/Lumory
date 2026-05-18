import Foundation
import CoreData
import Accelerate

// MARK: - InsightsSearchEngine
//
// **Search + RAG 子系统**(2026-05-16 round 3 从 InsightsEngine 拆出)。
// 持有跟 InsightsEngine 同一套 `persistence` + `ai` 注入。callsite 不直接接触 —— 通过
// `InsightsEngine.shared.searchSemantic(...)` / `.ask(...)` facade 转发(`InsightsEngine.init`
// 内部 `self.searchEngine = InsightsSearchEngine(persistence:ai:)`,跟主 engine 同生命周期)。
//
// **嵌套 types 不搬**:`SemanticSearchResult` / `AnswerChunk` 仍定义在 `InsightsEngine` 顶部,
// 本文件所有引用都用 `InsightsEngine.SemanticSearchResult` / `InsightsEngine.AnswerChunk`
// 完整 qualifier。把 nested type 一起搬过来会拖一片 view-layer caller 改 import / fully-qualify。
//
// **静态 helper 保 static 形态**:`cosineSimilarity` / `rankRetrieval` 是纯函数,
// 不依赖 instance state。保 static 让 `InsightsEngine` 侧的 forwarding wrapper(15+ tests
// 依赖 `InsightsEngine.cosineSimilarity` / `.rankRetrieval` 静态调用)只是一行直 forward,
// 不用绕到 instance。
//
// 本类不加 class-level `@MainActor` —— 跟 `InsightsEngine` 一致,实例方法可在任意 actor 调用,
// `ask()` 返 AsyncStream 不引新边界。
final class InsightsSearchEngine {
    // MARK: Dependencies

    private let persistence: PersistenceController
    private let ai: AIServiceProtocol

    init(persistence: PersistenceController, ai: AIServiceProtocol) {
        self.persistence = persistence
        self.ai = ai
    }

    // MARK: - Semantic search(F1)
    //
    // 跟 `ask` 同走两阶段检索 + cosine 排名,但**只返 NSManagedObjectID**,UI 自行 materialize 成
    // `DiaryEntry`(SwiftUI cell 直接吃 NSManagedObject,不用先转 DiaryEntryData)。跟 `retrieve()`
    // 不同的是这里**不**给"未索引保留槽":搜索用户想要的是按相关度排,新写的未索引日记夹在中间会
    // confusion;改成把 `indexCoverage` 透出来,UI 在覆盖率 < 95% 时显示"索引不完整"banner +
    // 引导用户去 Settings 一键重建。
    //
    // 失败路径:
    //   - query 空 → 空结果,coverage=1.0
    //   - 网络错(embed 返 nil)→ ids=空,coverage 仍正确(给 UI fallback 到关键词搜索的机会)
    //   - 全语料 0 embedding → ids=空,coverage=0
    //
    // 性能:1500 维 × 1000-2000 entries cosine ≈ 30-80ms 后台 actor;主线程零阻塞。
    // 调用方在 `.searchable` submit 时触发(用户按 return 键),不需要 typing debounce。

    /// F1 语义搜索入口。AI service 要返回 query 向量(embed 失败时 `queryEmbedded=false`,
    /// 调用方自行 fallback)。
    func searchSemantic(query: String, topK: Int = 20) async -> InsightsEngine.SemanticSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return InsightsEngine.SemanticSearchResult(ids: [], indexCoverage: 1.0, totalCount: 0, queryEmbedded: false)
        }

        let qVec = await ai.embed(text: trimmed)
        let queryEmbedded = qVec != nil

        return await persistence.container.performBackgroundTask { context -> InsightsEngine.SemanticSearchResult in
            // (megareview P1 #6)Phase A 改 `NSDictionaryResultType` 真投影 —— 之前的
            // `NSFetchRequest<DiaryEntry>` + `propertiesToFetch=["embedding","date"]` 只是 prefetch
            // hint,managedObjectResultType 下 SQL 仍 SELECT *,1000 entry × imagesData/text 全 row
            // cache 进 RAM(50-200MB peak)。改 dict-fetch 后只读 objectID + embedding-blob + date,
            // imagesData / text / summary / themes 完全不进 RAM。Phase B `materialize` 仍走 K 条
            // existingObject (fault) 是 OK 的。
            // `NSExpression.expressionForEvaluatedObject()` 拿 objectID 是 dict-fetch 标准 idiom。
            let objectIDExpr = NSExpressionDescription()
            objectIDExpr.name = "objectID"
            objectIDExpr.expression = NSExpression.expressionForEvaluatedObject()
            objectIDExpr.expressionResultType = .objectIDAttributeType

            let scanRequest = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
            scanRequest.resultType = .dictionaryResultType
            scanRequest.propertiesToFetch = [objectIDExpr, "embedding", "date"]
            scanRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]

            guard let rows = try? context.fetch(scanRequest), !rows.isEmpty else {
                return InsightsEngine.SemanticSearchResult(ids: [], indexCoverage: 1.0, totalCount: 0, queryEmbedded: queryEmbedded)
            }
            let totalCount = rows.count
            guard topK > 0 else {
                return InsightsEngine.SemanticSearchResult(ids: [], indexCoverage: 0.0, totalCount: totalCount, queryEmbedded: queryEmbedded)
            }

            // 无 query 向量 → 直接返空(让 UI 决定 fallback 策略,不偷偷返"最近 K 条"假装是相关结果)
            guard let qVec = qVec else {
                let withVecCount = rows.filter { ($0["embedding"] as? Data) != nil }.count
                let coverage = Double(withVecCount) / Double(max(1, totalCount))
                return InsightsEngine.SemanticSearchResult(ids: [], indexCoverage: coverage, totalCount: totalCount, queryEmbedded: false)
            }

            // 跟 retrieve() 同款 bounded heap(insertion sort),内存 O(K) 而非 O(N)。
            var topHeap: [(id: NSManagedObjectID, score: Float)] = []
            topHeap.reserveCapacity(topK)
            var withoutVecCount = 0
            var maxScore: Float = -.infinity
            for row in rows {
                guard let oid = row["objectID"] as? NSManagedObjectID else { continue }
                guard let blob = row["embedding"] as? Data,
                      let vec = DiaryEntry.decodeEmbeddingVector(blob) else {
                    withoutVecCount += 1
                    continue
                }
                let score = Self.cosineSimilarity(qVec, vec)
                if score > maxScore { maxScore = score }
                if topHeap.count < topK {
                    let insertAt = topHeap.firstIndex(where: { $0.score < score }) ?? topHeap.count
                    topHeap.insert((oid, score), at: insertAt)
                } else if let last = topHeap.last, score > last.score {
                    topHeap.removeLast()
                    let insertAt = topHeap.firstIndex(where: { $0.score < score }) ?? topHeap.count
                    topHeap.insert((oid, score), at: insertAt)
                }
            }

            let withVecCount = totalCount - withoutVecCount
            let coverage = Double(withVecCount) / Double(max(1, totalCount))

            // **P1 fix (2026-05-15 megareview, refined by 2026-05-15 superreview P2)**:
            // `cosineSimilarity` 在维度不匹配时返 0(legacy embedding 用旧 dim 写过,
            // index 仍有 embedding 字段但跟当前 query dim 不对齐)。全 0 score 时 bounded heap
            // 仍然填满前 K 条按日期降序的 entry,返回成"语义最相关"假象。
            //
            // 用 `abs()` —— query 跟所有 entry 都语义对立时 cosine 可能负且 max 仍接近 0
            // (例:query="开心快乐" + 全是负面 entry → 所有 entry 都 cosine ≈ -0.x,maxScore 是
            // 接近 -1 的值)。但 dim-mismatch 的 0 是真的接近 0,不是负值。**用 abs 抓 "全维度
            // 错配返 0" 这个特征**,既能挡 dim-mismatch 又不误伤"全负相关"的合法语义场景。
            // 真实空相关性场景由前面的 `withoutVecCount == totalCount` 路径覆盖。
            if withVecCount > 0 && abs(maxScore) < 1e-6 {
                Log.warning("[InsightsSearchEngine] searchSemantic: max cosine ≈ 0 across \(withVecCount) embeddings — dimension mismatch likely; returning empty", category: .ai)
                return InsightsEngine.SemanticSearchResult(
                    ids: [],
                    indexCoverage: 0.0,
                    totalCount: totalCount,
                    queryEmbedded: true
                )
            }

            // 注意:**不**保留 unindexed 槽位 — 搜索是按相关度排,不是 AI grounding。
            // 覆盖率不足时 UI 显示 banner 让用户主动去 Settings 重建。
            return InsightsEngine.SemanticSearchResult(
                ids: topHeap.map { $0.id },
                indexCoverage: coverage,
                totalCount: totalCount,
                queryEmbedded: true
            )
        }
    }

    // MARK: - Ask Your Past (RAG)

    func ask(_ question: String, topK: Int = 8) -> AsyncStream<InsightsEngine.AnswerChunk> {
        AsyncStream { continuation in
            let task = Task {
                guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continuation.finish()
                    return
                }

                let qVec = await self.ai.embed(text: question)
                let selected = await self.retrieve(query: question, queryVector: qVec, topK: topK)

                if !selected.isEmpty {
                    continuation.yield(InsightsEngine.AnswerChunk(citations: selected.map { $0.id }))
                }
                // 升级消费:走 askEvents,把 .truncated 单独冒泡给 UI
                // **streamLoop: label** — 裸 `break` 只跳 switch 不跳 for-await,
                // sibling consumer(NarrativeGenerationCoordinator / NarrativePrecomputeService)
                // 都用同款 label。当前 producer 自然 `continuation.finish()` 所以不暴露,
                // 但契约破洞 — MockAIService / 测试 producer 只 yield `.done` 不 close 会永久挂住。
                streamLoop: for await event in self.ai.askEvents(question: question, context: selected) {
                    if Task.isCancelled { break streamLoop }
                    switch event {
                    case .chunk(let text):
                        continuation.yield(InsightsEngine.AnswerChunk(text: text))
                    case .truncated(let reason):
                        continuation.yield(InsightsEngine.AnswerChunk(truncatedReason: reason))
                    case .failed(let error):
                        // **区分 truncated 和 failed**:truncated 是"断在中间,已有部分内容";
                        // failed 是"一点内容都没产出"(离线 / 401 / 5xx)。合并成 truncated 会让
                        // AskPastView 只显示空 bubble + 通用 banner,用户看不到具体错误。
                        continuation.yield(InsightsEngine.AnswerChunk(failureReason: error.localizedDescription))
                    case .done:
                        break streamLoop
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func retrieve(query: String, queryVector: [Float]?, topK: Int) async -> [DiaryEntryData] {
        // **两阶段检索**(Fix #20):
        //  Phase A —— 轻量扫:只 prefetch `embedding` + `date`,**不**触发 text/summary/themes/imagesData
        //             的 fault。1000 条 × 6KB embedding ≈ 6MB,vs 旧实现 15-30MB 全量物化。
        //             用 bounded top-K 数组(insertion sort)代替 O(N log N) 全排序,峰值内存 O(K) 而非 O(N)。
        //  Phase B —— 物化:拿 top-K objectIDs 回填完整 DiaryEntryData。每个 objectID 通过 fault 取数,
        //             成本和原方案的 mapping 一致,但只对 K 条。
        //
        // 无 query 向量 / 全无 embedding 走时间倒序兜底(语义见 rankRetrieval 注释),这条路径在 Phase A 内完成。
        return await persistence.container.performBackgroundTask { context -> [DiaryEntryData] in
            // (megareview P1 #6)Phase A 改 dict-fetch 真投影 —— 同 `searchSemantic` 改法,
            // 只读 objectID + embedding-blob + date,imagesData / text / summary 完全不进 RAM。
            let objectIDExpr = NSExpressionDescription()
            objectIDExpr.name = "objectID"
            objectIDExpr.expression = NSExpression.expressionForEvaluatedObject()
            objectIDExpr.expressionResultType = .objectIDAttributeType

            let scanRequest = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
            scanRequest.resultType = .dictionaryResultType
            scanRequest.propertiesToFetch = [objectIDExpr, "embedding", "date"]
            scanRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]

            guard let rows = try? context.fetch(scanRequest), !rows.isEmpty else { return [] }
            guard topK > 0 else { return [] }

            // 兜底路径:无 query 向量 → 直接取最近 topK,Phase B 时材料化
            guard let qVec = queryVector else {
                let ids = rows.prefix(topK).compactMap { $0["objectID"] as? NSManagedObjectID }
                return Self.materialize(objectIDs: Array(ids), in: context)
            }

            // 收集 (objectID, score),用 bounded min-heap 维护当前 top-K(K 通常 8-20):
            // 用 sorted insertion 模拟 —— `topHeap` 始终按 score 降序;新候选 < heap 末尾(最小值)直接丢,
            // 否则 insertion-sort 进去并把溢出末尾踢掉。K=20 时每次 insertion 最差 20 次比较。
            var topHeap: [(id: NSManagedObjectID, score: Float)] = []
            topHeap.reserveCapacity(topK)
            // 同步收集"无 embedding"的 objectID + date,以便最后做"未索引语料保留槽"逻辑(对齐 rankRetrieval 行为)。
            var withoutVecIDs: [(id: NSManagedObjectID, date: Date)] = []
            withoutVecIDs.reserveCapacity(rows.count)

            for row in rows {
                guard let oid = row["objectID"] as? NSManagedObjectID else { continue }
                let date = (row["date"] as? Date) ?? .distantPast
                guard let blob = row["embedding"] as? Data,
                      let vec = DiaryEntry.decodeEmbeddingVector(blob) else {
                    withoutVecIDs.append((oid, date))
                    continue
                }
                let score = Self.cosineSimilarity(qVec, vec)
                if topHeap.count < topK {
                    // 插入并保持降序
                    let insertAt = topHeap.firstIndex(where: { $0.score < score }) ?? topHeap.count
                    topHeap.insert((oid, score), at: insertAt)
                } else if let last = topHeap.last, score > last.score {
                    // 比当前最小分还高 —— 替换尾部,insertion-sort 到正确位置
                    topHeap.removeLast()
                    let insertAt = topHeap.firstIndex(where: { $0.score < score }) ?? topHeap.count
                    topHeap.insert((oid, score), at: insertAt)
                }
            }

            // 全语料无 embedding → 走时间兜底(rows 已按 date desc)
            guard !topHeap.isEmpty else {
                let ids = rows.prefix(topK).compactMap { $0["objectID"] as? NSManagedObjectID }
                return Self.materialize(objectIDs: Array(ids), in: context)
            }

            // 计算"未索引保留槽":覆盖率不到 95% 或有 5 分钟内新条目时,留 max(2, topK/3) 给最近未索引。
            // 与 rankRetrieval 的策略一致,只是这里直接对 objectID 操作,不必回填 DiaryEntryData。
            let totalCount = rows.count
            let withVecCount = totalCount - withoutVecIDs.count
            let indexCoverage = Double(withVecCount) / Double(max(1, totalCount))
            let now = Date()
            let hasFreshUnindexed = withoutVecIDs.contains { now.timeIntervalSince($0.date) < 300 }
            let minRecencyReserve: Int
            if !withoutVecIDs.isEmpty, indexCoverage < 0.95 || hasFreshUnindexed {
                minRecencyReserve = min(max(2, topK / 3), withoutVecIDs.count)
            } else {
                minRecencyReserve = 0
            }

            let maxSemanticSlots = max(0, topK - minRecencyReserve)
            let semanticIDs = topHeap.prefix(maxSemanticSlots).map { $0.id }
            let remainingSlots = max(0, topK - semanticIDs.count)
            // withoutVecIDs 来自按 date desc 的 scanned,所以它本身已按 date desc
            let recentUnindexed = withoutVecIDs.prefix(min(remainingSlots, withoutVecIDs.count)).map { $0.id }

            let finalIDs = Array(semanticIDs) + Array(recentUnindexed)

            // Phase B: 物化
            return Self.materialize(objectIDs: finalIDs, in: context)
        }
    }

    /// 把一批 objectID 物化成 `DiaryEntryData`。每个 `context.object(with:)` 是 cheap fault,
    /// 第一次访问其属性才会 round-trip 到 row cache。这里遍历完成后所有属性都被读过一次,
    /// 跨 context 边界返回值类型是安全的。
    /// `includeEmbedding=false`(默认):跳过 `embeddingVector` 解包,省 K × 6KB Float32 拷贝
    /// (retrieve Phase B 给 ask path 用,消费方只读 id / 文本字段,embedding 拷出来就丢)。
    private static func materialize(
        objectIDs: [NSManagedObjectID],
        in context: NSManagedObjectContext,
        includeEmbedding: Bool = false
    ) -> [DiaryEntryData] {
        objectIDs.compactMap { id in
            guard let entry = try? context.existingObject(with: id) as? DiaryEntry else { return nil }
            return DiaryEntryData(
                id: entry.id ?? UUID(),
                date: entry.date ?? Date(),
                text: entry.text ?? "",
                moodValue: entry.moodValue,
                summary: entry.summary ?? "",
                themes: entry.themeArray,
                embedding: includeEmbedding ? entry.embeddingVector : nil,
                wordCount: Int(entry.wordCount)
            )
        }
    }

    /// 纯函数版检索排名（方便单测）：
    ///  - 无 query 向量 → 按时间倒序返回 topK
    ///  - 全语料都没 embedding → 同上
    ///  - 有部分 embedded、部分没 embedded：**不能只看 embedded 那一半**，
    ///    否则 backfill 没跑完时 Ask Past / 语义搜索只看到索引过的语料子集，
    ///    对剩下的历史日记装聋作哑。现在预留 `topK` 的 1/3（夹在 2-5 之间）
    ///    给"最近但没建索引"的条目，让 AI 至少能看到新鲜未索引语料。
    static func rankRetrieval(
        all: [DiaryEntryData],
        queryVector: [Float]?,
        topK: Int
    ) -> [DiaryEntryData] {
        guard topK > 0, !all.isEmpty else { return [] }

        // 无 query 向量：时间倒序兜底
        guard let qVec = queryVector else {
            return Array(all.sorted { $0.date > $1.date }.prefix(topK))
        }

        let withVectors = all.filter { $0.embedding != nil }
        let withoutVectors = all.filter { $0.embedding == nil }

        // 全语料没 embedding：等于无 query 向量走兜底
        guard !withVectors.isEmpty else {
            return Array(all.sorted { $0.date > $1.date }.prefix(topK))
        }

        // 语义排名
        let scoredEmbedded: [DiaryEntryData] = withVectors
            .map { ($0, Self.cosineSimilarity(qVec, $0.embedding ?? [])) }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }

        // 只有两种情况才给最近未索引条目留保留槽:
        //   (a) 索引覆盖率不到 95% —— backfill 还没跑完,尾部未索引日记仍占相当比例
        //   (b) 5 分钟内有新写但未索引的条目 —— 用户刚写完马上问"刚才那条"的窗口
        // 其它情况(覆盖率 ≥ 95% 且无新鲜未索引)完全交给语义排名,避免把不相关的老条目塞进 context。
        let indexCoverage = Double(withVectors.count) / Double(max(1, all.count))
        let now = Date()
        let hasFreshUnindexed = withoutVectors.contains { now.timeIntervalSince($0.date) < 300 }
        let minRecencyReserve: Int
        if !withoutVectors.isEmpty, indexCoverage < 0.95 || hasFreshUnindexed {
            minRecencyReserve = min(max(2, topK / 3), withoutVectors.count)
        } else {
            minRecencyReserve = 0
        }

        let maxSemanticSlots = max(0, topK - minRecencyReserve)
        let topSemantic = Array(scoredEmbedded.prefix(maxSemanticSlots))

        let remainingSlots = max(0, topK - topSemantic.count)
        let recentNonIndexed = Array(
            withoutVectors
                .sorted { $0.date > $1.date }
                .prefix(min(remainingSlots, withoutVectors.count))
        )
        return topSemantic + recentNonIndexed
    }

    // MARK: - Math helpers

    /// 余弦相似度。长度不等时返回 0（而不是截断比较），避免误导。空向量返回 0。
    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        let count = vDSP_Length(lhs.count)
        var dot: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &dot, count)
        var aNorm: Float = 0
        vDSP_svesq(lhs, 1, &aNorm, count)
        var bNorm: Float = 0
        vDSP_svesq(rhs, 1, &bNorm, count)
        let denom = sqrt(aNorm) * sqrt(bNorm)
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
