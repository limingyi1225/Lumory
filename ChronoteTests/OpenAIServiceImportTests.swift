//
//  OpenAIServiceImportTests.swift
//  ChronoteTests
//
//  Tests for `OpenAIService.parseImportedDiaries` —— 通过 MockURLProtocol 注入 session,
//  绕过真后端验证 import 解析路径的所有 happy / 错误分支。
//
//  覆盖:
//   - 空输入 / 仅空白 → `.emptyInput`(早抛,不打网络)
//   - JSON payload schema 契约(field 名 + raw_text escape)
//   - HTTP 4xx/5xx(non-retryable)→ `.network`
//   - URLError(non-retryable 类)→ `.network`
//   - 200 + 空 content → `.parsingFailed`
//   - 200 + 非 JSON 数组 content → `.parsingFailed`
//   - 200 + 畸形 JSON → `.parsingFailed`
//   - 200 + 合法数组 → 返 [ParsedDiaryEntry]
//   - 200 + 含无效日期条目 → 该条 filter 掉
//   - 200 + 空数组 → 合法成功,返 []
//
//  **AppSecrets 解耦**:`chatThrowing` 头部 guard `appSharedSecret.isEmpty` 会在我们的
//  mock URLSession 前直接抛 401。原来用 `XCTSkipIf` 跳过整个 suite —— codex review P2 指出
//  这让干净 clone / CI 上跑 0 条回归测试也能"green"。现在通过 `OpenAIService` init 注入
//  dummy secret,不改全局 AppSecrets,任意环境都能跑这套 mock 测试。
//
//  **网络重试 vs 测试速度**:用 non-retryable 错误(HTTP 401 / URLError.badServerResponse)
//  让测试快速失败,而非走 1s+2s+4s exponential backoff。

import XCTest
@testable import Lumory

@available(iOS 15.0, macOS 12.0, *)
final class OpenAIServiceImportTests: XCTestCase {

    private var service: OpenAIService!

    override func setUp() async throws {
        try await super.setUp()
        // Codex P2 fix: 注入 dummy secret 而非 XCTSkipIf 真值缺失。让 MockURLProtocol 路径
        // 跟 Lumory.local.xcconfig 是否存在解耦,fresh clone / CI 也能跑。
        service = OpenAIService(session: MockURLProtocol.makeSession(), appSharedSecret: "test-secret")
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        service = nil
        try await super.tearDown()
    }

    // MARK: - 输入校验(不打网络)

    func test_emptyInput_throwsEmptyInput() async {
        do {
            _ = try await service.parseImportedDiaries(rawText: "")
            XCTFail("应抛 .emptyInput")
        } catch DiaryImportError.emptyInput {
            // ok
        } catch {
            XCTFail("应抛 .emptyInput,实际 \(error)")
        }
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 0,
                       "空输入不应打网络")
    }

    func test_whitespaceOnlyInput_throwsEmptyInput() async {
        do {
            _ = try await service.parseImportedDiaries(rawText: "   \n\t  ")
            XCTFail("应抛 .emptyInput")
        } catch DiaryImportError.emptyInput {
            // ok
        } catch {
            XCTFail("应抛 .emptyInput,实际 \(error)")
        }
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 0)
    }

    // MARK: - JSON payload schema 契约

    func test_encodeImportPayload_schemaShape() throws {
        let date = ISO8601DateFormatter().date(from: "2026-05-16T12:00:00Z")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let json = try OpenAIService.encodeImportPayload(
            rawText: "test content", today: date, calendar: cal
        )
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["raw_text"] as? String, "test content")
        XCTAssertEqual(parsed?["client_today"] as? String, "2026-05-16")
        XCTAssertEqual(parsed?["client_year"] as? Int, 2026)
    }

    /// Codex P1 fix regression test: client_today / client_year **必须同时区**。
    ///
    /// 旧实现 client_today 走 `ISO8601DateFormatter`(UTC default),client_year 走 caller calendar。
    /// 纽约用户 5/15 晚上 23:00(= UTC 03:00 5/16):
    ///   - 旧:client_today="2026-05-16" (UTC) + client_year=2026
    ///   - 一条无年份 "5/16" 日记 → prompt 规则"日期晚于 client_today 用 year-1" → 误判为本年(应为去年)
    /// 修后两个字段都按 caller calendar.timeZone:client_today="2026-05-15" + client_year=2026,逻辑一致。
    func test_encodeImportPayload_nonUTCBoundary_usesLocalDate() throws {
        // 纽约 2026-05-15 23:00 EDT = UTC 2026-05-16 03:00
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let nyEvening = cal.date(from: DateComponents(
            year: 2026, month: 5, day: 15, hour: 23, minute: 0
        ))!

        let json = try OpenAIService.encodeImportPayload(
            rawText: "x", today: nyEvening, calendar: cal
        )
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["client_today"] as? String, "2026-05-15",
                       "本地日期必须用 calendar.timeZone,不能用 UTC")
        XCTAssertEqual(parsed?["client_year"] as? Int, 2026)
    }

    func test_encodeImportPayload_nonGregorianCalendarStillUsesGregorianISOYear() throws {
        var cal = Calendar(identifier: .buddhist)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = ISO8601DateFormatter().date(from: "2026-05-16T12:00:00Z")!

        let json = try OpenAIService.encodeImportPayload(
            rawText: "x", today: date, calendar: cal
        )
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["client_today"] as? String, "2026-05-16")
        XCTAssertEqual(parsed?["client_year"] as? Int, 2026,
                       "Import payload must stay Gregorian/ISO even when the user's system calendar is non-Gregorian.")
    }

    func test_encodeImportPayload_escapesDelimitersAsDefenseInDepth() throws {
        let json = try OpenAIService.encodeImportPayload(
            rawText: ">>>attack<<< normal text",
            today: Date()
        )
        XCTAssertFalse(json.contains(">>>"), "raw_text 内的 >>> 必须被替成全角")
        XCTAssertFalse(json.contains("<<<"), "raw_text 内的 <<< 必须被替成全角")
        XCTAssertTrue(json.contains("\u{203A}\u{203A}\u{203A}"))
        XCTAssertTrue(json.contains("\u{2039}\u{2039}\u{2039}"))
    }

    // MARK: - 请求 wire 验证(prompt 真的包含我们的 JSON payload)

    func test_requestBody_carriesEncodedPayloadInPromptContent() async throws {
        MockURLProtocol.requestHandler = Self.handler(status: 200, content: "[]")
        _ = try await service.parseImportedDiaries(rawText: "用户输入 with >>>delim<<<")

        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 1)
        let request = MockURLProtocol.recordedRequests[0].request
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-App-Secret"), "test-secret")

        let body = try XCTUnwrap(MockURLProtocol.recordedRequests[0].body, "请求 body 应非空")
        let outer = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = try XCTUnwrap(outer?["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? String)
        let payload = try inputPayload(fromPrompt: content)

        XCTAssertEqual(payload["raw_text"] as? String, "用户输入 with \u{203A}\u{203A}\u{203A}delim\u{2039}\u{2039}\u{2039}")
        XCTAssertNotNil(payload["client_today"] as? String)
        XCTAssertNotNil(payload["client_year"] as? Int)
    }

    // MARK: - 网络错误路径

    func test_http401_throwsNetwork() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }
        await assertThrowsNetwork(rawText: "随便写点")
    }

    func test_http400_throwsNetwork() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }
        await assertThrowsNetwork(rawText: "随便写点")
    }

    func test_urlError_throwsNetwork() async throws {
        // 用 non-retryable URLError(.badServerResponse / .cannotFindHost 都不在
        // NetworkRetryHelper retry 列表),让测试快速失败而非走 3 轮 exponential backoff。
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cannotFindHost)
        }
        await assertThrowsNetwork(rawText: "随便写点")
    }

    // MARK: - 解析失败路径(200 OK 但内容有问题)

    func test_emptyContent_throwsParsingFailed() async throws {
        // chatThrowing 在 empty content 时 throw NSError(code: -2),parseImportedDiaries
        // catch all → .parsingFailed
        MockURLProtocol.requestHandler = Self.handler(status: 200, content: "")
        await assertThrowsParsingFailed(rawText: "随便写点")
    }

    func test_nonJSONArrayContent_throwsParsingFailed() async throws {
        // 模型返了文字但完全不含 [ ] —— notJSON 分支
        MockURLProtocol.requestHandler = Self.handler(
            status: 200,
            content: "这只是一段说明文字,完全不像 JSON 数组。"
        )
        await assertThrowsParsingFailed(rawText: "随便写点")
    }

    func test_malformedJSONInsideBrackets_throwsParsingFailed() async throws {
        // [ ] 都在,但内部 JSON 不能 decode
        MockURLProtocol.requestHandler = Self.handler(
            status: 200,
            content: "[{not valid json}]"
        )
        await assertThrowsParsingFailed(rawText: "随便写点")
    }

    // MARK: - 正常路径

    func test_validResponse_returnsParsedEntries() async throws {
        MockURLProtocol.requestHandler = Self.handler(
            status: 200,
            content: #"[{"date":"2023-10-01","text":"国庆"},{"date":"2023-10-02","text":"下雨"}]"#
        )
        let entries = try await service.parseImportedDiaries(rawText: "2023-10-01: 国庆\n2023-10-02: 下雨")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].text, "国庆")
        XCTAssertEqual(entries[1].text, "下雨")
    }

    func test_invalidDatesAreFilteredOut() async throws {
        // 模型返了 entries,某条 date 无法解析 → 该条被 filter 掉,其他保留
        MockURLProtocol.requestHandler = Self.handler(
            status: 200,
            content: #"[{"date":"2023-10-01","text":"valid"},{"date":"not-a-date","text":"invalid"}]"#
        )
        let entries = try await service.parseImportedDiaries(rawText: "irrelevant")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.text, "valid")
    }

    func test_emptyArrayResponse_isSuccess() async throws {
        // 模型读完认定"里面没有日记结构" → 返空数组。
        // 这是**合法成功**,UI 后续单独处理"导入 0 条"的语义。
        MockURLProtocol.requestHandler = Self.handler(status: 200, content: "[]")
        let entries = try await service.parseImportedDiaries(rawText: "毫无日记结构的随机文字")
        XCTAssertEqual(entries.count, 0)
    }

    // MARK: - Helpers

    /// 构造一个返回 chat completion 响应壳的 handler(content 字段填可控字符串)。
    private static func handler(status: Int, content: String) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        return { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body: [String: Any] = [
                "choices": [
                    [
                        "message": [
                            "role": "assistant",
                            "content": content
                        ]
                    ]
                ]
            ]
            return (response, try JSONSerialization.data(withJSONObject: body))
        }
    }

    private func inputPayload(fromPrompt prompt: String,
                              file: StaticString = #filePath,
                              line: UInt = #line) throws -> [String: Any] {
        guard let markerRange = prompt.range(of: "# Input\n\n") else {
            XCTFail("Prompt should contain # Input marker", file: file, line: line)
            return [:]
        }
        let json = String(prompt[markerRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any], "Input payload should be a JSON object", file: file, line: line)
    }

    private func assertThrowsNetwork(rawText: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await service.parseImportedDiaries(rawText: rawText)
            XCTFail("应抛 .network", file: file, line: line)
        } catch DiaryImportError.network {
            // ok
        } catch {
            XCTFail("应抛 .network,实际 \(error)", file: file, line: line)
        }
    }

    private func assertThrowsParsingFailed(rawText: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await service.parseImportedDiaries(rawText: rawText)
            XCTFail("应抛 .parsingFailed", file: file, line: line)
        } catch DiaryImportError.parsingFailed {
            // ok
        } catch {
            XCTFail("应抛 .parsingFailed,实际 \(error)", file: file, line: line)
        }
    }
}
