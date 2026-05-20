//
//  OpenAITranscriberTests.swift
//  ChronoteTests
//
//  Tests for `OpenAITranscriber.prepareUpload`(本地路径):
//   - 25MB 阈值 → throws `.audioTooLarge`
//   - 文件不存在 → throws `.audioReadFailed`
//   - 空文件(0 bytes) → throws `.audioReadFailed`
//   - 正常 m4a → 返 multipart body + Lumory- 前缀 boundary + audio/mp4 mime
//
//  + Tests for `transcribeAudio` 网络路径(2026-05-16 加,leverage MockURLProtocol 基建):
//   - 空 secret guard / 4xx 5xx 分类 / non-retryable URLError / 200 成功 wire shape /
//     trim / 空 text 返 nil
//   8 条新 test 锁住网络 contract,跟 OpenAIServiceImportTests 同一 mock 模式。
//

import XCTest
@testable import Lumory

@available(iOS 15.0, macOS 12.0, *)
@MainActor
final class OpenAITranscriberTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenAITranscriberTests-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Error paths

    /// 文件路径不存在 → audioReadFailed
    func testPrepareUpload_missingFile_throwsAudioReadFailed() {
        let missing = tempDir.appendingPathComponent("does-not-exist.m4a")
        XCTAssertThrowsError(try OpenAITranscriber.prepareUploadForTesting(fileURL: missing)) { error in
            XCTAssertEqual(error as? TranscriptionFailure, .audioReadFailed,
                           "missing file must throw .audioReadFailed (not generic / not .audioTooLarge)")
        }
    }

    /// 文件存在但 0 bytes → audioReadFailed(避免上送空 body)
    func testPrepareUpload_emptyFile_throwsAudioReadFailed() throws {
        let empty = tempDir.appendingPathComponent("empty.m4a")
        try Data().write(to: empty)

        XCTAssertThrowsError(try OpenAITranscriber.prepareUploadForTesting(fileURL: empty)) { error in
            XCTAssertEqual(error as? TranscriptionFailure, .audioReadFailed,
                           "0-byte file should throw .audioReadFailed")
        }
    }

    /// (round-5 D3)用 sparse file(`FileHandle.truncate(atOffset:)`)造 25MB 文件 size,
    /// 实际不占盘(APFS hole)。`prepareUpload` 内 `attributesOfItem.size` guard 走 `>` 路径
    /// 直接 throw,根本读不到 mapped data。原版每次 test 真写 25MB+1 byte 真数据,CI 累积浪费。
    private func makeSparseFile(at url: URL, size: UInt64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }

    /// 文件 > 25MB → audioTooLarge
    func testPrepareUpload_overMaxBytes_throwsAudioTooLarge() throws {
        let maxBytes = OpenAITranscriber.maxFileBytesForTesting
        let oversize = tempDir.appendingPathComponent("huge.m4a")

        try makeSparseFile(at: oversize, size: UInt64(maxBytes) + 1)

        XCTAssertThrowsError(try OpenAITranscriber.prepareUploadForTesting(fileURL: oversize)) { error in
            XCTAssertEqual(error as? TranscriptionFailure, .audioTooLarge,
                           "file exceeding maxFileBytes (25 MB) must throw .audioTooLarge,不能跟 generic 错误混")
        }
    }

    /// 文件 == 25MB(边界条件)— 应该过(`<= maxFileBytes` 是 inclusive)
    func testPrepareUpload_exactlyMaxBytes_succeeds() throws {
        let maxBytes = OpenAITranscriber.maxFileBytesForTesting
        let atLimit = tempDir.appendingPathComponent("at-limit.m4a")

        try makeSparseFile(at: atLimit, size: UInt64(maxBytes))

        XCTAssertNoThrow(try OpenAITranscriber.prepareUploadForTesting(fileURL: atLimit),
                         "size == maxFileBytes 是 inclusive 上限,应该不抛")
    }

    // MARK: - Multipart construction

    /// 小 m4a 文件 → 返一份 multipart body,boundary 形如 "Lumory-<UUID>",mime "audio/mp4"。
    func testPrepareUpload_smallM4A_buildsMultipartCorrectly() throws {
        let valid = tempDir.appendingPathComponent("voice.m4a")
        try Data(repeating: 0xAB, count: 1024).write(to: valid) // 1KB 假音频

        let result = try OpenAITranscriber.prepareUploadForTesting(fileURL: valid)

        XCTAssertGreaterThan(result.bodyByteCount, 1024,
                             "multipart body 必须比原音频大(含 boundary headers + form fields)")
        XCTAssertTrue(result.boundary.hasPrefix("Lumory-"),
                      "boundary 必须用 Lumory- 前缀(便于调试 / 抓包)")
        XCTAssertGreaterThan(result.boundary.count, "Lumory-".count + 16,
                             "boundary 后段是 UUID,至少 16 字符")
        XCTAssertEqual(result.mimeType, "audio/mp4", "m4a 文件 → mime audio/mp4")
    }

    /// 不同扩展名 → 正确 mime 类型(mimeTypeFor 是 mapping table,简单 spot-check)。
    func testPrepareUpload_mimeTypeMapping() throws {
        let cases: [(ext: String, mime: String)] = [
            ("m4a", "audio/mp4"),
            ("mp3", "audio/mpeg"),
            ("wav", "audio/wav"),
            ("webm", "audio/webm"),
            ("ogg", "audio/ogg"),
            ("flac", "audio/flac"),
            ("xyz", "application/octet-stream") // 未知扩展名兜底
        ]

        for (ext, expectedMime) in cases {
            let file = tempDir.appendingPathComponent("sample.\(ext)")
            try Data(repeating: 0xCD, count: 64).write(to: file)
            let result = try OpenAITranscriber.prepareUploadForTesting(fileURL: file)
            XCTAssertEqual(result.mimeType, expectedMime,
                           ".\(ext) 文件应该 map 到 \(expectedMime)")
        }
    }

    // MARK: - TranscriptionFailure equatable

    /// `TranscriptionFailure` 是 Equatable,但 `.serverError(Int)` 关联值参与比较 — 防 future 失误。
    func testTranscriptionFailure_serverErrorEqualityIsCodeSensitive() {
        XCTAssertEqual(TranscriptionFailure.serverError(413), TranscriptionFailure.serverError(413))
        XCTAssertNotEqual(TranscriptionFailure.serverError(413), TranscriptionFailure.serverError(500))
        XCTAssertNotEqual(TranscriptionFailure.serverError(413), TranscriptionFailure.audioTooLarge)
    }

    // MARK: - Network path tests via MockURLProtocol (2026-05-16)
    //
    // **基建**:`OpenAITranscriber.init(session:, appSharedSecret:)` 注入 seam + MockURLProtocol
    // 让 transcribeAudio 真发请求路径跟生产 sharedRetrySession + AppSecrets 解耦。
    //
    // **测试速度**:用 non-retryable 错码(HTTP 401/413/501 + URLError.cannotFindHost)避免
    // NetworkRetryHelper 3 轮 backoff(1s+2s+4s)。HTTP 500-599 默认 retryable,只 501 是
    // NetworkRetryHelper.swift:86 明确排除的 5xx,用 501 测 non-retryable 5xx 路径。
    //
    // **fixture 音频文件**:prepareUpload 只校验 file exists + size > 0 + size <= 25MB,
    // 不验 m4a 内部结构。写几 byte 占位即可让控制流走到 URLSession。

    /// 写一个最小 valid file 让 prepareUpload 过到 URLSession 阶段(本类 test fixture 共享)。
    private func makeNetworkFixtureAudio() throws -> URL {
        let url = tempDir.appendingPathComponent("net-fixture.m4a")
        // 几 byte 随意内容 — prepareUpload 不读 m4a 内部结构,只看 size > 0 且 <= 25MB
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        return url
    }

    /// (1) 注入空 `appSharedSecret` → 顶部 guard 早返 `.sharedSecretMissing`,**不打** URLSession。
    func testTranscribe_emptySharedSecret_skipsURLSession() async throws {
        let audioURL = try makeNetworkFixtureAudio()
        let transcriber = OpenAITranscriber(
            session: MockURLProtocol.makeSession(),
            appSharedSecret: ""
        )
        defer { MockURLProtocol.reset() }
        let countBefore = MockURLProtocol.recordedRequests.count
        MockURLProtocol.requestHandler = { _ in
            // 故意 fail-loud:guard 漏接的话会先撞这里,assertion 立刻 fail
            throw URLError(.cannotFindHost)
        }

        let result = await transcriber.transcribeAudio(fileURL: audioURL, localeIdentifier: "en")
        XCTAssertNil(result)
        XCTAssertEqual(transcriber.lastFailure, .sharedSecretMissing)
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, countBefore,
                       "guard 应在 URLSession 前抛,不该有 mock 请求被记录")
    }

    /// (2) HTTP 401(non-retryable) → `.serverError(401)`,1 个请求。
    func testTranscribe_http401_serverError() async throws {
        try await assertNetworkStatusServerError(401)
    }

    /// (3) HTTP 413(non-retryable) → `.serverError(413)`,1 个请求。
    func testTranscribe_http413_serverError() async throws {
        try await assertNetworkStatusServerError(413)
    }

    /// (4) HTTP 501(non-retryable;NetworkRetryHelper 唯一明确排除的 5xx) → `.serverError(501)`,1 个请求。
    /// 其他 500-599 默认 retryable,会跑 3 次 + 1s+2s+4s backoff = 测试 7s,违反"高 ROI 快测试"原则。
    func testTranscribe_http501_serverError_nonRetryable() async throws {
        try await assertNetworkStatusServerError(501)
    }

    /// (5) `URLError(.cannotFindHost)`(non-retryable URLError) → `.networkFailed`,1 个请求。
    func testTranscribe_urlError_networkFailed() async throws {
        let audioURL = try makeNetworkFixtureAudio()
        let transcriber = OpenAITranscriber(
            session: MockURLProtocol.makeSession(),
            appSharedSecret: "test-secret"
        )
        defer { MockURLProtocol.reset() }
        MockURLProtocol.requestHandler = { _ in throw URLError(.cannotFindHost) }

        let result = await transcriber.transcribeAudio(fileURL: audioURL, localeIdentifier: "en")
        XCTAssertNil(result)
        XCTAssertEqual(transcriber.lastFailure, .networkFailed)
    }

    /// (6) 200 + 完整 wire 契约 verify:返 trimmed text + 请求 POST / X-App-Secret /
    /// Accept / Content-Type 含 multipart/form-data / body 非空。比单纯 assert 返 "hello" 高一个 量级。
    func testTranscribe_success_returnsTrimmedTextAndLocksWireContract() async throws {
        let audioURL = try makeNetworkFixtureAudio()
        let transcriber = OpenAITranscriber(
            session: MockURLProtocol.makeSession(),
            appSharedSecret: "test-secret"
        )
        defer { MockURLProtocol.reset() }
        MockURLProtocol.requestHandler = Self.successHandler(text: "  hello world  ")

        let result = await transcriber.transcribeAudio(fileURL: audioURL, localeIdentifier: "en")
        XCTAssertEqual(result, "hello world", "应 trim 前后空格")
        XCTAssertNil(transcriber.lastFailure)

        // wire shape 锁:本应发什么 header / method / body
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 1)
        let req = MockURLProtocol.recordedRequests[0].request
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-App-Secret"), "test-secret")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
        let contentType = req.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.contains("multipart/form-data"),
                      "Content-Type 应是 multipart/form-data;实际 \(contentType)")
        XCTAssertTrue(contentType.contains("boundary=Lumory-"),
                      "boundary 应是 Lumory- 前缀;实际 \(contentType)")
        let body = try XCTUnwrap(MockURLProtocol.recordedRequests[0].body)
        XCTAssertGreaterThan(body.count, 0, "multipart body 应非空")
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("name=\"prompt\""), "转写请求应带 prompt 限定中英自动检测")
        XCTAssertTrue(
            bodyText.contains(OpenAITranscriber.transcriptionPromptForTesting),
            "multipart prompt 应包含 OpenAITranscriber.transcriptionPrompt"
        )
        XCTAssertFalse(bodyText.contains("name=\"language\""),
                       "用户可能说中文或英文,不应把转写固定到某一个 language")
    }

    /// (7) 200 + `{"text":""}` → 返 nil(service 把空 text 转 nil),`lastFailure` 不动。
    func testTranscribe_emptyText_returnsNil() async throws {
        let audioURL = try makeNetworkFixtureAudio()
        let transcriber = OpenAITranscriber(
            session: MockURLProtocol.makeSession(),
            appSharedSecret: "test-secret"
        )
        defer { MockURLProtocol.reset() }
        MockURLProtocol.requestHandler = Self.successHandler(text: "")

        let result = await transcriber.transcribeAudio(fileURL: audioURL, localeIdentifier: "en")
        XCTAssertNil(result, "空 text 应转 nil(service line 109 isEmpty 检测)")
        XCTAssertNil(transcriber.lastFailure, "空 text 不算失败,lastFailure 不动")
    }

    /// (8) 200 + 只有空白 → trim 后为空 → 返 nil。
    func testTranscribe_whitespaceOnlyText_returnsNil() async throws {
        let audioURL = try makeNetworkFixtureAudio()
        let transcriber = OpenAITranscriber(
            session: MockURLProtocol.makeSession(),
            appSharedSecret: "test-secret"
        )
        defer { MockURLProtocol.reset() }
        MockURLProtocol.requestHandler = Self.successHandler(text: "   \n\t  ")

        let result = await transcriber.transcribeAudio(fileURL: audioURL, localeIdentifier: "en")
        XCTAssertNil(result, "trim 后为空也应转 nil")
        XCTAssertNil(transcriber.lastFailure)
    }

    // MARK: - Network test helpers

    /// 共用断言:某 HTTP 状态码 → `.serverError(code)` + 仅 1 个请求(non-retryable 路径)。
    private func assertNetworkStatusServerError(_ status: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let audioURL = try makeNetworkFixtureAudio()
        let transcriber = OpenAITranscriber(
            session: MockURLProtocol.makeSession(),
            appSharedSecret: "test-secret"
        )
        defer { MockURLProtocol.reset() }
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        let result = await transcriber.transcribeAudio(fileURL: audioURL, localeIdentifier: "en")
        XCTAssertNil(result, file: file, line: line)
        XCTAssertEqual(transcriber.lastFailure, .serverError(status),
                       "HTTP \(status) → .serverError(\(status))", file: file, line: line)
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 1,
                       "non-retryable \(status) 应只发 1 次请求, 不走 NetworkRetryHelper 重试",
                       file: file, line: line)
    }

    /// 返 200 + `{"text": "<text>"}` chat completion 风格的 mock 响应。
    /// 跟 OpenAI 实际响应字段一致:`{"text": "..."}`(line 105 `TranscriptionResponse.text`)。
    private static func successHandler(text: String) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        return { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body: [String: Any] = ["text": text]
            let data = try JSONSerialization.data(withJSONObject: body)
            return (response, data)
        }
    }
}
