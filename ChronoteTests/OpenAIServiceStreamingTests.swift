//
//  OpenAIServiceStreamingTests.swift
//  ChronoteTests
//
//  Wire-level SSE 翻译层测试(megareview OPT-HIGH H6)。
//
//  覆盖 `OpenAIService.streamReportEvents` 把 OpenAI SSE 字节流 → `StreamEvent` enum 的关键路径:
//   - 正常 chunks + finish_reason="stop" + [DONE] → 多个 .chunk + .done(无 .truncated)
//   - chunks + finish_reason="length" → .chunk + .truncated(锁住"max_completion_tokens 撞顶"路径)
//   - 已 yield chunk 后 stream 错误 / EOF → .truncated(non-empty body 不视为彻底 failed)
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

    /// 拼一条 OpenAI SSE 事件帧:`data: {json}\n\n`。
    private func sseFrame(_ json: String) -> String {
        "data: \(json)\n\n"
    }

    /// 构造一条 chunk JSON。`finishReason` 可选 — 通常只在最后一帧带 "stop" / "length"。
    private func chunkJSON(content: String?, finishReason: String? = nil) -> String {
        var deltaPart = "{}"
        if let content {
            let escaped = content
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            deltaPart = "{\"content\":\"\(escaped)\"}"
        }
        let reasonPart = finishReason.map { "\"\($0)\"" } ?? "null"
        return "{\"choices\":[{\"delta\":\(deltaPart),\"finish_reason\":\(reasonPart)}]}"
    }

    private func makeSSEBody(frames: [String], appendDone: Bool = true) -> Data {
        var body = frames.map { sseFrame($0) }.joined()
        if appendDone {
            body += "data: [DONE]\n\n"
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

    /// 正常完成:多个 chunk + finish_reason="stop" + [DONE] → 收到 .chunk×N + .done,**不**带 .truncated。
    func test_streamReportEvents_normalCompletion_emitsChunksAndDone() async {
        let frames = [
            chunkJSON(content: "[HEADLINE]\n"),
            chunkJSON(content: "晴天散步\n[BODY]\n"),
            chunkJSON(content: "今天心情不错。", finishReason: "stop")
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
        XCTAssertEqual(chunkCount, 3, "三条 data 帧应该 yield 三个 .chunk")
        XCTAssertFalse(events.contains { if case .truncated = $0 { return true }; return false },
                       "finish_reason=stop 不应触发 .truncated")
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

    /// finish_reason="length"(超 max_completion_tokens) → 最后一条 chunk 仍 yield + emit .truncated。
    /// 锁住"max_completion_tokens 撞顶"路径不会丢掉最末 chunk 的 content(P1 fix 2026-05-13)。
    func test_streamReportEvents_finishReasonLength_emitsTruncated() async {
        let frames = [
            chunkJSON(content: "[HEADLINE]\n散步\n[BODY]\n开头"),
            chunkJSON(content: "中段写了一些", finishReason: "length")  // 这条 content 必须先 yield 再标 truncated
        ]
        let body = makeSSEBody(frames: frames, appendDone: false)
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
                       "finish_reason=length 也要把当条 content 先 yield 出去,P1 fix 锁定")
        XCTAssertTrue(chunkContents.last?.contains("中段") == true,
                       "最末 chunk 的 content 不能因为 truncated 提前 return 丢掉")

        let truncatedCount = events.filter { if case .truncated = $0 { return true }; return false }.count
        XCTAssertEqual(truncatedCount, 1, "finish_reason=length 应 emit 一条 .truncated")
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false },
                       "truncated 不应同时被归类为 failed")
    }

    /// finish_reason="content_filter" 也应触发 .truncated(同 hasTruncatedFinish 逻辑)。
    func test_streamReportEvents_finishReasonContentFilter_emitsTruncated() async {
        let frames = [
            chunkJSON(content: "开头", finishReason: "content_filter")
        ]
        let body = makeSSEBody(frames: frames, appendDone: false)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": "text/event-stream"])!
            return (response, body)
        }

        let events = await collectEvents(service.streamReportEvents(entries: fakeEntries()))
        XCTAssertTrue(events.contains { if case .truncated = $0 { return true }; return false },
                       "content_filter 也应被 hasTruncatedFinish 识别")
    }

    /// 无 [DONE] 收尾:SSEParser 在 EOF 未见 [DONE] 时 `throw ParserError.missingDone`
    /// ([SSEParser.swift](Chronote/Services/OpenAI/SSEParser.swift) line 182)。
    /// `generateReportFromData` catch 路径在 `hasEmittedAnyChunk=true` 时 emit `.truncated`
    /// (line 205-209,reason="Report incomplete (connection interrupted)"),**非** `.done` /  `.failed`。
    /// codex P3 followup:锁住"已 yield chunk 后 server 没发 [DONE] → .truncated"的语义,
    /// 防 future 把 missingDone 抹掉或改成 .failed(用户会看红 banner 而非"内容不完整"提示)。
    func test_streamReportEvents_noDoneMarkerAfterChunk_emitsTruncated() async {
        let frames = [
            chunkJSON(content: "一行 headline\n[BODY]\n一段 body")
        ]
        let body = makeSSEBody(frames: frames, appendDone: false)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": "text/event-stream"])!
            return (response, body)
        }

        let events = await collectEvents(service.streamReportEvents(entries: fakeEntries()))
        let chunkCount = events.filter { if case .chunk = $0 { return true }; return false }.count
        XCTAssertGreaterThanOrEqual(chunkCount, 1, "应至少 yield 一个 chunk")
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false },
                       "已 yield chunk + 缺 [DONE] 路径不应归 .failed(.failed 仅在 hasEmittedAnyChunk=false 时)")
        XCTAssertFalse(events.contains { if case .done = $0 { return true }; return false },
                       "SSEParser throws missingDone → catch path,不走 line 200-202 的 .done emit")
        guard case .truncated = events.last else {
            XCTFail("缺 [DONE] 已 yield chunk 路径终态应为 .truncated,实际 events=\(events)")
            return
        }
    }
}
