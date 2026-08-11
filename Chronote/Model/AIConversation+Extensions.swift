import Foundation
import CoreData

// MARK: - AIConversation 业务逻辑入口
//
// CoreData entity 字段全 optional(CloudKit-first-sync 安全),业务层访问通过下面这些
// 计算属性 / helper。`kind` 不留 free string,通过 `Kind` enum wrap;`payload` 是 JSON
// 编码的结构化 DTO 并带 `payloadVersion`(每次 schema 变化 bump,反序列化时按版本分支)。
//
// **wave12-2 落地的 schema(payloadVersion = 1)**:
//   - kind="askPast"  → payload = AskPastConversationPayload(messages[]: AskMessageDTO)
//     一次 Q + A pair = 一条记录(InsightsEngine.ask 不累积 session,见 codex review)
//   - kind="narrative" → payload = NarrativeReportPayload(rangeStart, rangeEnd, body, title)
//     每生成一份报告 = 一条记录,包含日期范围
//
// **CitedEntryIds**:都用同一个 JSON `[UUID]` 编码进 `citedEntryIds`(独立字段而非
// payload 内,方便未来按 citation 做 reverse-lookup query;CoreData 不支持 to-many
// 关系跨 CloudKit cascade,直接 JSON 更可靠)。

extension AIConversation {
    // MARK: - Kind enum(避免 free-string 误用)

    enum Kind: String, CaseIterable {
        case askPast
        case narrative
    }

    var kindEnum: Kind? {
        guard let raw = kind else { return nil }
        return Kind(rawValue: raw)
    }

    // MARK: - 编码后的 payload(JSON,带 payloadVersion 版本 gate)

    /// AskPast 一次 Q+A pair 的持久化 DTO。**不存** SwiftUI 的 `AskPastView.Message`
    /// 整个结构(那是 view-state DTO,含 isStreaming 这种瞬态字段)。
    struct AskPastPayload: Codable, Equatable {
        struct Message: Codable, Equatable {
            enum Role: String, Codable {
                case user
                case ai
            }
            let role: Role
            let text: String
            let citedEntryIds: [UUID]
            /// 流被中断但已产部分内容(`stream.truncated`)。UI 渲染加警示。
            let isIncomplete: Bool
            /// 流彻底失败(零内容)的 errorText。和 isIncomplete 互斥。
            let errorText: String?
        }
        let messages: [Message]
    }

    /// Narrative 一份报告的持久化 DTO。`rangeStart` / `rangeEnd` 让历史详情页面能显示
    /// "2026年5月" / "最近30天"等(仅 startEnd 时间戳,UI 自己 format 跟语言走)。
    ///
    /// **v2 (payloadVersion=2)**:加 `rangeKind / entryCount / sourceLatestEntryDate / generatedAt`
    /// 让 InsightsView 顶部浓缩卡能按"语义 range"(.month/.quarter/.year/.all)而非滚动
    /// 区间精确匹配查 cache。
    ///
    /// **v3 (payloadVersion=3)**:加 `headline` —— 重活模型一次输出 [HEADLINE]\\n一两句诗\\n[BODY]\\n长文,
    /// 客户端 stream 收完后 split。卡收起态显 headline,tap 进 detail 显 body。v2 老 cache 没 headline
    /// → view 层 fallback 用 body 第一段第一句作 placeholder,不强制重生。
    struct NarrativePayload: Codable, Equatable {
        let rangeStart: Date
        let rangeEnd: Date
        /// 完整报告 markdown 文本(可能含 truncated 标记/不完整段落 — UI 显示时复用同
        /// 一套渲染逻辑,带 isIncomplete 状态)。
        let body: String
        let isIncomplete: Bool
        /// 截断时的原因(stream.truncated.report 等)。完整时 nil。
        let truncatedReason: String?

        // v2 additions —— rangeKind == nil 表示 v1 record。
        let rangeKind: String?
        let entryCount: Int?
        let sourceLatestEntryDate: Date?
        let generatedAt: Date?

        // v3 addition —— headline 一两句诗意 summary,模型不守 marker 时 nil → view 层 fallback。
        let headline: String?

        /// 自定义 init —— Swift memberwise init 即使字段是 optional 也要求传值,
        /// 不写 custom init 旧 v1 callsite 编不过。
        init(
            rangeStart: Date,
            rangeEnd: Date,
            body: String,
            isIncomplete: Bool,
            truncatedReason: String?,
            rangeKind: String? = nil,
            entryCount: Int? = nil,
            sourceLatestEntryDate: Date? = nil,
            generatedAt: Date? = nil,
            headline: String? = nil
        ) {
            self.rangeStart = rangeStart
            self.rangeEnd = rangeEnd
            self.body = body
            self.isIncomplete = isIncomplete
            self.truncatedReason = truncatedReason
            self.rangeKind = rangeKind
            self.entryCount = entryCount
            self.sourceLatestEntryDate = sourceLatestEntryDate
            self.generatedAt = generatedAt
            self.headline = headline
        }

        var payloadVersion: Int32 {
            // - rangeKind == nil → v1(老 callsite)
            // - rangeKind != nil + headline == nil → v2
            // - rangeKind != nil + headline != nil → v3
            rangeKind == nil ? 1 : (headline != nil ? 3 : 2)
        }
    }

    // MARK: - 写入 helper(显式赋 id/createdAt,不依赖 CoreData model default)

    /// 在 context 上 insert 一条 AIConversation,把 payload 编码进去。**调用方负责 save()**。
    /// 失败(JSON 编码 throw)抛 CocoaError;调用方处理。
    @discardableResult
    static func insertAskPast(
        in context: NSManagedObjectContext,
        title: String,
        payload: AskPastPayload,
        citedEntryIds: [UUID]
    ) throws -> AIConversation {
        let conv = AIConversation(context: context)
        conv.id = UUID()
        conv.kind = Kind.askPast.rawValue
        conv.createdAt = Date()
        conv.title = title
        conv.payloadVersion = 1
        conv.payload = try JSONEncoder().encode(payload)
        conv.citedEntryIds = try JSONEncoder().encode(citedEntryIds)
        conv.content = "" // 兼容 schema 字段(future fields 用 payload,content 弃用但留着)
        return conv
    }

    @discardableResult
    static func insertNarrative(
        in context: NSManagedObjectContext,
        title: String,
        payload: NarrativePayload,
        citedEntryIds: [UUID]
    ) throws -> AIConversation {
        let conv = AIConversation(context: context)
        conv.id = UUID()
        conv.kind = Kind.narrative.rawValue
        conv.createdAt = Date()
        conv.title = title
        conv.payloadVersion = payload.payloadVersion
        conv.payload = try JSONEncoder().encode(payload)
        conv.citedEntryIds = try JSONEncoder().encode(citedEntryIds)
        conv.content = ""
        return conv
    }

    // MARK: - 读取 helper(版本 gate,未识别版本 → nil)

    /// **payloadVersion guard 用 `>= 1`** 不是 `== 1`(coredata-migration-reviewer P2 反馈)。
    /// `payloadVersion: Int32` 是 scalar(usesScalarValueType=YES),CloudKit pull 的老 record
    /// 字段缺失时会**读出 0**(不是 nil 也不是 default)。`>= 1` future-proof:写新 schema v2
    /// 时只需在 helper bump 写值,旧 client 看到 v2 record `payloadVersion=2 >= 1` 仍走解码路径,
    /// 但 JSON decode 会按需 fail(payload 结构变了);零字段 / 老缺失 record `payloadVersion=0`
    /// 直接跳过,不会被错认成 v1。
    var askPastPayload: AskPastPayload? {
        guard kindEnum == .askPast, payloadVersion >= 1, let data = payload else { return nil }
        return try? JSONDecoder().decode(AskPastPayload.self, from: data)
    }

    var narrativePayload: NarrativePayload? {
        guard kindEnum == .narrative, payloadVersion >= 1, let data = payload else { return nil }
        return try? JSONDecoder().decode(NarrativePayload.self, from: data)
    }

    var citedEntryUUIDs: [UUID] {
        guard let data = citedEntryIds else { return [] }
        return (try? JSONDecoder().decode([UUID].self, from: data)) ?? []
    }
}
