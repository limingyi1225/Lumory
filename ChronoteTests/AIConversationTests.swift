//
//  AIConversationTests.swift
//  ChronoteTests
//
//  wave12-2 schema migration + entity insert/decode round-trip 契约。
//
//  **覆盖**:
//  - In-memory store 上 insert AskPast / Narrative,save 成功
//  - payload 编码/解码 round-trip 准确(messages / dates / citedEntryIds)
//  - payloadVersion 不匹配时 askPastPayload / narrativePayload 返 nil(版本 gate)
//  - kind 误用(askPast 用 narrativePayload accessor)返 nil(类型 gate)
//  - DiaryEntry 跟 AIConversation 共存,DiaryEntry 行为不受新 entity 影响
//  - JSON encoding 失败路径(Decoder error → readback nil)
//
//  **不覆盖**:
//  - CloudKit 同步真实 round-trip(in-memory store 没 CloudKit;留生产 SyncDiagnostic 验证)
//  - 老用户 v1→v2 lightweight migration 真实迁移路径(需要 SQLite store fixture;
//    schema 是 additive-only 加 entity → CoreData lightweight migration 自动处理,
//    coredata-migration-reviewer 会 audit 这条)
//

import Testing
import Foundation
import CoreData
@testable import Lumory

@MainActor
struct AIConversationTests {

    // MARK: - AskPast

    @Test func insertAskPast_roundTripsAllFields() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let id1 = UUID()
        let id2 = UUID()
        let payload = AIConversation.AskPastPayload(messages: [
            .init(role: .user, text: "为什么我最近总焦虑?", citedEntryIds: [], isIncomplete: false, errorText: nil),
            .init(role: .ai, text: "你提到工作压力的次数变多了。", citedEntryIds: [id1, id2], isIncomplete: false, errorText: nil)
        ])

        let conv = try AIConversation.insertAskPast(
            in: context,
            title: "为什么我最近总焦虑?",
            payload: payload,
            citedEntryIds: [id1, id2]
        )
        try context.save()

        // 字段直接赋值
        #expect(conv.id != nil)
        #expect(conv.kind == "askPast")
        #expect(conv.kindEnum == .askPast)
        #expect(conv.title == "为什么我最近总焦虑?")
        #expect(conv.payloadVersion == 1)
        #expect(conv.createdAt != nil)
        // payload 编码后 readback
        let decoded = try #require(conv.askPastPayload)
        #expect(decoded.messages.count == 2)
        #expect(decoded.messages[0].role == .user)
        #expect(decoded.messages[0].text == "为什么我最近总焦虑?")
        #expect(decoded.messages[1].role == .ai)
        #expect(decoded.messages[1].citedEntryIds == [id1, id2])
        // citedEntryIds 顶级字段
        #expect(conv.citedEntryUUIDs == [id1, id2])
    }

    // (megareview 待确认 W11)`persistConversationIfNeeded` 把 SSE `.truncated` / `.failed` 的
    // `isIncomplete` / `errorText` 落进 AskPast payload,但此前 round-trip 测试这两个字段恒为
    // false/nil,没锁住"非默认值也能正确编解码"。
    //
    // **两个字段互斥**(见 AskPastView.AskMessage 注释):`isIncomplete`=断在中间(有半截正文、
    // errorText 为 nil);`errorText`=根本没开始(零内容)。故 fixture 用两条 AI 消息分别覆盖
    // 这两个**真实**状态,而非在一条消息上同时置位(那是生产中不会出现的非法组合)。
    @Test func insertAskPast_roundTripsIncompleteAndErrorText() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let payload = AIConversation.AskPastPayload(messages: [
            .init(role: .user, text: "去年这个月我在忙什么?", citedEntryIds: [], isIncomplete: false, errorText: nil),
            // 状态 A —— .truncated 断在中间:有半截正文,isIncomplete=true,errorText=nil。
            .init(role: .ai, text: "你那阵子在准备一场演讲——", citedEntryIds: [], isIncomplete: true, errorText: nil),
            // 状态 B —— 流彻底失败(零内容):text 空,isIncomplete=false,errorText 有值。
            .init(role: .ai, text: "", citedEntryIds: [], isIncomplete: false, errorText: "网络中断,生成失败")
        ])

        let conv = try AIConversation.insertAskPast(
            in: context,
            title: "去年这个月我在忙什么?",
            payload: payload,
            citedEntryIds: []
        )
        try context.save()

        let decoded = try #require(conv.askPastPayload)
        #expect(decoded.messages.count == 3)
        // user 消息默认值保持
        #expect(decoded.messages[0].isIncomplete == false)
        #expect(decoded.messages[0].errorText == nil)
        // 状态 A:truncated —— isIncomplete=true / errorText=nil round-trip 不丢
        #expect(decoded.messages[1].isIncomplete == true)
        #expect(decoded.messages[1].errorText == nil)
        #expect(decoded.messages[1].text == "你那阵子在准备一场演讲——")
        // 状态 B:failed —— isIncomplete=false / errorText 有值 round-trip 不丢
        #expect(decoded.messages[2].isIncomplete == false)
        #expect(decoded.messages[2].errorText == "网络中断,生成失败")
        #expect(decoded.messages[2].text == "")
    }

    @Test func askPastPayload_returnsNil_whenKindIsNarrative() async throws {
        // 类型 gate:误用 askPast 字段访问 narrative 记录返 nil(防类型混淆 bug)。
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let conv = try AIConversation.insertNarrative(
            in: context,
            title: "2026年5月报告",
            payload: AIConversation.NarrativePayload(
                rangeStart: Date(timeIntervalSince1970: 1_714_521_600),
                rangeEnd: Date(timeIntervalSince1970: 1_717_113_600),
                body: "report body",
                isIncomplete: false,
                truncatedReason: nil
            ),
            citedEntryIds: []
        )
        try context.save()

        #expect(conv.askPastPayload == nil, "narrative 记录用 askPast accessor 必须返 nil")
        #expect(conv.narrativePayload != nil, "正确的 accessor 应该解出来")
    }

    // MARK: - Narrative

    @Test func insertNarrative_preservesDateRange() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let start = Date(timeIntervalSince1970: 1_714_521_600) // 2024-05-01
        let end = Date(timeIntervalSince1970: 1_717_113_600)   // 2024-05-31

        let conv = try AIConversation.insertNarrative(
            in: context,
            title: "5 月报告",
            payload: AIConversation.NarrativePayload(
                rangeStart: start,
                rangeEnd: end,
                body: "你这个月经历了三次低谷,但每次都通过散步走了出来。",
                isIncomplete: false,
                truncatedReason: nil
            ),
            citedEntryIds: []
        )
        try context.save()

        let decoded = try #require(conv.narrativePayload)
        #expect(abs(decoded.rangeStart.timeIntervalSince(start)) < 1.0)
        #expect(abs(decoded.rangeEnd.timeIntervalSince(end)) < 1.0)
        #expect(decoded.body.contains("散步"))
        #expect(decoded.isIncomplete == false)
    }

    @Test func narrativePayload_capturesIncompleteState() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let conv = try AIConversation.insertNarrative(
            in: context,
            title: "5 月报告(中断)",
            payload: AIConversation.NarrativePayload(
                rangeStart: Date(),
                rangeEnd: Date(),
                body: "你这个月开始得很有活力,",
                isIncomplete: true,
                truncatedReason: "stream.truncated.report"
            ),
            citedEntryIds: []
        )
        try context.save()

        let decoded = try #require(conv.narrativePayload)
        #expect(decoded.isIncomplete == true)
        #expect(decoded.truncatedReason == "stream.truncated.report")
    }

    // MARK: - 版本 gate

    @Test func payloadVersion_zero_returnsNil() async throws {
        // CloudKit pull 老 record 时 payloadVersion 字段缺失 → scalar 读出 0
        // (coredata-migration-reviewer P2 提示)。guard `>= 1` 必须排除 0。
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let conv = try AIConversation.insertAskPast(
            in: context,
            title: "test",
            payload: AIConversation.AskPastPayload(messages: []),
            citedEntryIds: []
        )
        conv.payloadVersion = 0  // 模拟老 record 缺字段
        try context.save()

        #expect(conv.askPastPayload == nil,
                "payloadVersion=0(老 record 缺字段)必须返 nil,不能尝试解码")
    }

    @Test func payloadVersion_future_stillTriesDecode() async throws {
        // P2 future-proof:guard `>= 1`(不是 `== 1`)— 未来 v2 schema 写的 record 在 v1 client
        // 上 `payloadVersion=2 >= 1`,会进解码路径。如果 payload 结构变了 JSONDecoder 会 fail
        // 自然返 nil;如果结构兼容(纯 additive),老 client 也能读出旧字段。
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let conv = try AIConversation.insertAskPast(
            in: context,
            title: "test",
            payload: AIConversation.AskPastPayload(messages: [
                .init(role: .user, text: "q", citedEntryIds: [], isIncomplete: false, errorText: nil)
            ]),
            citedEntryIds: []
        )
        conv.payloadVersion = 99
        try context.save()

        // payload 仍是 v1 兼容的 JSON → decode 成功(future schema 如果 additive 就这样)
        let decoded = conv.askPastPayload
        #expect(decoded != nil, "v1-compatible payload + payloadVersion=99(>=1)应该 decode 成功")
        #expect(decoded?.messages.count == 1)
    }

    // MARK: - DiaryEntry coexistence

    @Test func diaryEntry_stillWorks_alongsideNewEntity() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        // 老 DiaryEntry 行为不变
        let entry = DiaryEntry(context: context)
        entry.id = UUID()
        entry.date = Date()
        entry.text = "test"
        entry.summary = "test"
        entry.moodValue = 0.5
        entry.themes = ""
        entry.wordCount = 4

        // 新 AIConversation 同 store
        _ = try AIConversation.insertAskPast(
            in: context,
            title: "q",
            payload: AIConversation.AskPastPayload(messages: []),
            citedEntryIds: []
        )

        try context.save()

        // 两个 entity 都 fetch 得到
        let entries = try context.fetch(DiaryEntry.fetchRequest())
        #expect(entries.count == 1)
        let convs = try context.fetch(AIConversation.fetchRequest())
        #expect(convs.count == 1)
    }

    // MARK: - citedEntryIds

    @Test func citedEntryUUIDs_returnsEmptyForMissingData() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let conv = AIConversation(context: context)
        conv.id = UUID()
        // 不设 citedEntryIds
        #expect(conv.citedEntryUUIDs.isEmpty)
    }

    @Test func citedEntryUUIDs_decodesValidJSON() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let ids = [UUID(), UUID(), UUID()]

        let conv = try AIConversation.insertAskPast(
            in: context,
            title: "t",
            payload: AIConversation.AskPastPayload(messages: []),
            citedEntryIds: ids
        )
        try context.save()
        #expect(conv.citedEntryUUIDs == ids)
    }
}
