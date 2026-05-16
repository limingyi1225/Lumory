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
//  **AppSecrets 依赖**:`chatThrowing` 先 guard `appSharedSecret.isEmpty`。AppSecrets 走
//  Bundle.main → 测试 host 同享 Info.plist,本地 Lumory.local.xcconfig 设置正常时即非空。
//  缺失则 XCTSkip(避免 false 错断)。
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
        try XCTSkipIf(
            AppSecrets.appSharedSecret.isEmpty,
            "Skipping: APP_SHARED_SECRET not configured (Lumory.local.xcconfig missing). See AppSecrets.swift."
        )
        service = OpenAIService(session: MockURLProtocol.makeSession())
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
        let body = try XCTUnwrap(MockURLProtocol.recordedRequests[0].body, "请求 body 应非空")
        let outer = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = try XCTUnwrap(outer?["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? String)

        // prompt 文本里要出现真正的 payload 字段(用唯一的 raw 输入子串锚定,排除文档段误命中)
        XCTAssertTrue(content.contains("用户输入 with"),
                      "prompt 应包含用户原文(已 escape 形式)")
        XCTAssertFalse(content.contains(">>>delim<<<"),
                       "delimiter 必须被 escape")
        XCTAssertTrue(content.contains("\"raw_text\""))
        XCTAssertTrue(content.contains("\"client_today\""))
        XCTAssertTrue(content.contains("\"client_year\""))
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
            let escaped = content
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            let body = #"{"choices":[{"message":{"role":"assistant","content":"\#(escaped)"}}]}"#
            return (response, Data(body.utf8))
        }
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
