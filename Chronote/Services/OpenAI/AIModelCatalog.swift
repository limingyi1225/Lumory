import Foundation

/// 客户端发给后端代理的模型名 —— **全仓唯一真源**。
///
/// 2026-08-11 从 gpt-5.5 / gpt-5.4-mini 全线升到 gpt-5.6 家族。此前模型名以字符串字面量散在
/// 8 个 callsite(OpenAIService + 5 个 extension 文件),换代要逐个 grep,漏一个就出现"两代模型
/// 混跑"且没人发现。集中到这里之后换代只改一处。
///
/// **信任边界仍在服务端**:`server/index.js` 的 `CHAT_MODEL_ALLOWLIST` + `resolveChatModel`
/// 才是最终决定权 —— 这里传什么都可能被服务端改写(不在 allowlist 就落 `CHAT_DEFAULT_MODEL`)。
/// 服务端同时保留一张 legacy alias 表(`gpt-5.5` → terra / `gpt-5.4-mini` → luna),所以
/// **老版本 App 不用等审核就已经在跑新模型**;本文件是给新 build 用的,让它别再依赖那张表。
///
/// reasoning effort 由 callsite 按活儿轻重传,服务端 `MODEL_EFFORT_POLICY` 会按模型能力做二次
/// 收敛(只放行 none/low/medium/high,`xhigh` / `max` 挡掉防成本失控)。
enum AIModel {
    /// 重活:narrative 生成 / Ask-Your-Past / 导入解析 / 主题别名判定 / 建议语。
    /// gpt-5.6 家族的均衡档 —— 比旗舰 sol 便宜一个身位,日记这种长文场景质量足够。
    static let heavy = "gpt-5.6-terra"

    /// 轻活:心情打分 / 标签抽取。走 `reasoningEffort: "none"` 零推理开销,
    /// 这两个任务的 prompt 都已显式列出判定档位,不需要模型推理。
    static let light = "gpt-5.6-luna"

    /// Embedding 模型。**这个值在服务端会被忽略** —— `/api/openai/embeddings` 路由硬编码
    /// `EMBEDDING_MODEL`,不读 client 传的 `model` 字段(信任边界同转写)。留在这里只为让
    /// 请求体保持完整 + 标明当前实际用的是哪个模型。
    ///
    /// **换 embedding 模型不是改这一行就完事**:向量空间变了,CoreData 里存量 `embedding`
    /// 字段全部作废,语义搜索 / Ask-Your-Past 的召回会静默退化成噪声,必须配套跑
    /// `EmbeddingBackfillService` 全量重算。要换先当独立任务做。
    static let embedding = "text-embedding-3-small"
}
