//
//  OpenAIServiceStreamingTests.swift
//  ChronoteTests
//
//  Wire-level SSE 翻译层测试(megareview OPT-HIGH H6;2026-06-11 GPT→Claude 迁移后
//  wire 形状换成 Anthropic 帧:content_block_delta / message_delta / message_stop)。
//
//  覆盖 `OpenAIService.streamReportEvents` 把 Anthropic SSE 字节流 → `StreamEvent` enum 的关键路径:
//   - 正常 text_delta×N + message_delta(end_turn) + message_stop → 多个 .chunk + .done(无 .truncated)
//   - text_delta + message_delta(stop_reason=max_tokens) → .chunk + .truncated(锁住"max_tokens 撞顶"路径)
//   - 已 yield chunk 后 stream 错误 / EOF(无 message_stop)→ .truncated(non-empty body 不视为彻底 failed)
//
//  历史 bug 复盘:reviewer 之前发现 `AsyncLineSequence` 在 iOS 26 不为空行 yield ""→ SSEParser
//  失去 dispatch 信号 → 所有 chunk 粘成一坨 throw invalidEvent → 整流哑掉但服务端 200。
//  纯 SSEParser 单测覆盖底层切分,这里覆盖**SSE → StreamEvent → caller 消费侧**全链路,
//  catch parser → state machine → caller event 翻译层任一漂移。
//
//  XCTest framework(对齐 OpenAIServiceImportTests,统一 setUp/tearDown 风格)。

import XCTest
@testable import Lumory

@available(iOS 15.0, macOS 12.0, *)
final class OpenAIServiceStreamingTests: XCTestCase {

    private var service: OpenAIService!
    private struct RequestBody: Decodable {
        struct Message: Decodable { let content: String }
        let messages: [Message]
    }

    override func setUp() async throws {
        try await super.setUp()
        service = OpenAIService(session: MockURLProtocol.makeSession(), appSharedSecret: "test-secret")
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        service = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// 拼一条 SSE 事件帧:`data: {json}\n\n`(SSEParser 忽略 `event:` 行,只看 data payload
    /// 里的 `type` 判别字段,mock 不必带 event 行)。
    private func sseFrame(_ json: String) -> String {
        "data: \(json)\n\n"
    }

    /// Anthropic 文本增量帧。
    private func textDeltaJSON(_ content: String) -> String {
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(escaped)\"}}"
    }

    /// Anthropic 收尾信号帧(stop_reason 在 message_delta 帧,不在内容帧上)。
    private func stopJSON(reason: String) -> String {
        "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(reason)\"}}"
    }

    private func makeSSEBody(frames: [String], appendStop: Bool = true) -> Data {
        var body = frames.map { sseFrame($0) }.joined()
        if appendStop {
            body += sseFrame("{\"type\":\"message_stop\"}")
        }
        return body.data(using: .utf8)!
    }

    private func fakeEntries() -> [DiaryEntryData] {
        // 至少一条 entry 避免 generateReportFromData 早退到 .done
        let entry = DiaryEntryData(
            id: UUID(),
            date: Date(timeIntervalSince1970: 1_700_000_000),
            text: "今天阳光不错,散了一会儿步。",
            moodValue: 0.7,
            summary: "散步",
            themes: ["户外"],
            embedding: nil,
            wordCount: 12
        )
        return [entry]
    }

    /// 收集 streamReportEvents 全部 yield 的事件。
    private func collectEvents(_ stream: AsyncStream<StreamEvent>) async -> [StreamEvent] {
        var events: [StreamEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    // MARK: - Tests

    /// 正常完成:多个 text_delta + message_delta(end_turn) + message_stop → 收到 .chunk×N + .done,
    /// **不**带 .truncated。
    func test_streamReportEvents_normalCompletion_emitsChunksAndDone() async {
        let frames = [
            textDeltaJSON("[HEADLINE]\n"),
            textDeltaJSON("晴天散步\n[BODY]\n"),
            textDeltaJSON("今天心情不错。"),
            stopJSON(reason: "end_turn")
        ]
        let body = makeSSEBody(frames: frames)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, body)
        }

        let events = await collectEvents(service.streamReportEvents(entries: fakeEntries()))

        // 3 个 .chunk + 终态 .done(P1 fix 2026-05-13:即便 finish_reason=stop 也走 line 200 emit .done)
        let chunkCount = events.filter { if case .chunk = $0 { return true }; return false }.count
        XCTAssertEqual(chunkCount, 3, "三条 text_delta 帧应该 yield 三个 .chunk")
        XCTAssertFalse(events.contains { if case .truncated = $0 { return true }; return false },
                       "stop_reason=end_turn 不应触发 .truncated")
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false },
                       "正常完成路径不应 emit .failed")
        // **显式锁定终态 .done**(codex P3 followup):`generateReportFromData` line 200 在没 emit
        // 过 truncated/failed 时 unconditional emit `.done`。锁住"streamReportEvents 一定以 .done
        // 结尾"的契约,防 future refactor 把 line 200 删了导致流静默结束。
        guard case .done = events.last else {
            XCTFail("正常完成的 stream 末尾必须是 .done event,实际 events=\(events)")
            return
        }
    }

    /// stop_reason="max_tokens"(撞 max_tokens 上限)→ 内容帧全部 yield + emit .truncated。
    /// Anthropic 把 stop_reason 放在内容帧之后的独立 message_delta 帧,内容天然先 yield 完,
    /// 不存在旧 OpenAI "最后一条 chunk 同时带 content + finish_reason" 的丢末段问题。
    func test_streamReportEvents_finishReasonLength_emitsTruncated() async {
        let frames = [
            textDeltaJSON("[HEADLINE]\n散步\n[BODY]\n开头"),
            textDeltaJSON("中段写了一些"),
            stopJSON(reason: "max_tokens")
        ]
        let body = makeSSEBody(frames: frames, appendStop: false)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, body)
        }

        let events = await collectEvents(service.streamReportEvents(entries: fakeEntries()))

        // 必须 yield 2 个 chunk + 1 个 .truncated
        let chunkContents = events.compactMap { event -> String? in
            if case .chunk(let s) = event { return s } else { return nil }
        }
        XCTAssertEqual(chunkContents.count, 2,
                       "stop_reason=max_tokens 前的内容帧都要 yield 出去")
        XCTAssertTrue(chunkContents.last?.contains("中段") == true,
                       "最末 chunk 的 content 不能因为 truncated 提前 return 丢掉")

        let truncatedCount = events.filter { if case .truncated = $0 { return true }; return false }.count
        XCTAssertEqual(truncatedCount, 1, "stop_reason=max_tokens 应 emit 一条 .truncated")
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false },
                       "truncated 不应同时被归类为 failed")
    }

    /// stop_reason="refusal" 也应触发 .truncated(对应旧 content_filter 语义,
    /// 同 isTruncatedStop 逻辑)。
    func test_streamReportEvents_finishReasonContentFilter_emitsTruncated() async {
        let frames = [
            textDeltaJSON("开头"),
            stopJSON(reason: "refusal")
        ]
        let body = makeSSEBody(frames: frames, appendStop: false)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": "text/event-stream"])!
            return (response, body)
        }

        let events = await collectEvents(service.streamReportEvents(entries: fakeEntries()))
        XCTAssertTrue(events.contains { if case .truncated = $0 { return true }; return false },
                       "refusal 也应被 isTruncatedStop 识别")
    }

    /// 无 message_stop 收尾:SSEParser 在 EOF 未见 [DONE](Anthropic 流里不存在)时
    /// `throw ParserError.missingDone`。`streamClaudeChatEvents` catch 路径在
    /// `hasEmittedAnyChunk=true` 时 emit `.truncated`,**非** `.done` / `.failed`。
    /// codex P3 followup:锁住"已 yield chunk 后 server 没发成功终止帧 → .truncated"的语义,
    /// 防 future 把 missingDone 抹掉或改成 .failed(用户会看红 banner 而非"内容不完整"提示)。
    func test_streamReportEvents_noDoneMarkerAfterChunk_emitsTruncated() async {
        let frames = [
            textDeltaJSON("一行 headline\n[BODY]\n一段 body")
        ]
        let body = makeSSEBody(frames: frames, appendStop: false)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": "text/event-stream"])!
            return (response, body)
        }

        let events = await collectEvents(service.streamReportEvents(entries: fakeEntries()))
        let chunkCount = events.filter { if case .chunk = $0 { return true }; return false }.count
        XCTAssertGreaterThanOrEqual(chunkCount, 1, "应至少 yield 一个 chunk")
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false },
                       "已 yield chunk + 缺终止帧路径不应归 .failed(.failed 仅在 hasEmittedAnyChunk=false 时)")
        XCTAssertFalse(events.contains { if case .done = $0 { return true }; return false },
                       "SSEParser throws missingDone → catch path,不应 emit .done")
        guard case .truncated = events.last else {
            XCTFail("缺终止帧已 yield chunk 路径终态应为 .truncated,实际 events=\(events)")
            return
        }
    }

    func test_askEvents_trimsLargeQuestionAndContextBeforeSending() async throws {
        let body = makeSSEBody(frames: [textDeltaJSON("ok")])
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, body)
        }

        let entries = (0..<6).map { index in
            DiaryEntryData(
                id: UUID(),
                date: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index)),
                text: String(repeating: "很长的日记内容", count: 5_000),
                moodValue: 0.5,
                summary: "",
                themes: [],
                embedding: nil,
                wordCount: 50_000
            )
        }
        _ = await collectEvents(service.askEvents(
            question: String(repeating: "这个问题也很长", count: 1_000),
            context: entries
        ))

        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 1)
        let requestBody = try XCTUnwrap(MockURLProtocol.recordedRequests.first?.body)

        let decoded = try JSONDecoder().decode(RequestBody.self, from: requestBody)
        let prompt = try XCTUnwrap(decoded.messages.first?.content)
        XCTAssertLessThanOrEqual(prompt.utf16.count, 31_000)
        XCTAssertTrue(prompt.contains("用户问题"))
        XCTAssertTrue(prompt.contains("相关日记"))
    }

    func test_askEvents_trimsLargeEnglishQuestionAndContextBeforeSending() async throws {
        let body = makeSSEBody(frames: [textDeltaJSON("ok")])
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, body)
        }

        let entries = (0..<6).map { index in
            DiaryEntryData(
                id: UUID(),
                date: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index)),
                text: String(repeating: "very long diary content ", count: 5_000),
                moodValue: 0.5,
                summary: "",
                themes: [],
                embedding: nil,
                wordCount: 50_000
            )
        }
        _ = await collectEvents(service.askEvents(
            question: String(repeating: "This question is also very long. ", count: 1_000),
            context: entries
        ))

        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 1)
        let requestBody = try XCTUnwrap(MockURLProtocol.recordedRequests.first?.body)
        let decoded = try JSONDecoder().decode(RequestBody.self, from: requestBody)
        let prompt = try XCTUnwrap(decoded.messages.first?.content)
        XCTAssertLessThanOrEqual(prompt.utf16.count, 31_000)
        XCTAssertTrue(prompt.contains("Question:"))
        XCTAssertTrue(prompt.contains("Relevant entries:"))
        XCTAssertFalse(prompt.contains("用户问题"))
    }
}
