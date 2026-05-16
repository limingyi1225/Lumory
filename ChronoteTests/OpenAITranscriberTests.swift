//
//  OpenAITranscriberTests.swift
//  ChronoteTests
//
//  Tests for `OpenAITranscriber.prepareUpload`:
//   - 25MB 阈值 → throws `.audioTooLarge`
//   - 文件不存在 → throws `.audioReadFailed`
//   - 空文件(0 bytes) → throws `.audioReadFailed`
//   - 正常 m4a → 返 multipart body + Lumory- 前缀 boundary + audio/mp4 mime
//
//  **不测**:网络路径(`transcribeAudio` 调真 OpenAI 后端,需要 URLProtocol mock,本批不做)。
//

import XCTest
@testable import Lumory

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
}
