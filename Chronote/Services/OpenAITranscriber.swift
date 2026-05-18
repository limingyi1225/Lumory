import Foundation

/// 走 Lumory 后端代理 OpenAI `gpt-4o-mini-transcribe` 的转写实现。
///
/// 流程:
///   1. 后台 Task 读取 m4a + 拼 multipart/form-data(避免 25 MB 文件落在 main actor)
///   2. 主线程发出 `POST /api/openai/audio/transcriptions`(后端 hardcode 模型,不读 client `model` 字段)
///   3. 解析 `{"text": "..."}` JSON 响应
///
/// 失败映射(写入 `lastFailure`,UI 据此决定是否给重试按钮):
///   - 文件读不到 / 不存在 → `.audioReadFailed`
///   - 文件 > 25 MB → `.audioTooLarge`(本地预检,省一次 multipart 上传)
///   - URLError / 客户端超时 → `.networkFailed`
///   - 401 / 413 / 429 / 5xx → `.serverError(code)`(`.audioTooLarge` 走预检覆盖,服务端 413 走 .serverError)
///   - shared secret 没注入 → `.sharedSecretMissing`
@available(iOS 15.0, macOS 12.0, *)
@MainActor
final class OpenAITranscriber: TranscriberProtocol {
    // 这两个 static let 给 nonisolated `prepareUpload` 用,Swift 6 严格并发要求显式
    // `nonisolated` —— 否则它们会继承类的 MainActor 隔离,从后台 Task 访问报错。
    nonisolated private static let endpoint = "\(AppSecrets.backendURL)/api/openai/audio/transcriptions"
    /// 和后端 `MAX_TRANSCRIPTION_FILE_BYTES` 对齐 —— OpenAI 上限 25 MB。
    /// 客户端预检让用户在拨号前就知道"文件太大",省一次失败上传。
    nonisolated private static let maxFileBytes: Int64 = 25 * 1024 * 1024

    private let backendURL: URL
    private let jsonDecoder = JSONDecoder()

    /// URLSession 注入点。生产走 `.sharedRetrySession`(默认),URLProtocol-mocked 单测可传 mock session。
    /// 跟 `OpenAIService` 的 session 注入模式对齐(2026-05-16 superreview P1 #2 fix)。
    let session: URLSession

    /// 后端共享密钥注入点。生产走 `AppSecrets.appSharedSecret`(默认),单测可注入 dummy。
    /// 跟 `OpenAIService.init(appSharedSecret:)` 对齐 —— 整个 OpenAI service surface 一套约定。
    let appSharedSecret: String

    private(set) var lastFailure: TranscriptionFailure?

    init(
        session: URLSession = .sharedRetrySession,
        appSharedSecret: String = AppSecrets.appSharedSecret
    ) {
        guard let url = URL(string: Self.endpoint) else {
            preconditionFailure("[OpenAITranscriber] Invalid backend endpoint: \(Self.endpoint)")
        }
        self.backendURL = url
        self.session = session
        self.appSharedSecret = appSharedSecret
    }

    func transcribeAudio(fileURL: URL, localeIdentifier _: String) async -> String? {
        // 注:`localeIdentifier` 故意忽略。AppStorage `appLanguage` 取值是 `zh-Hans` / `zh-Hant` /
        // `en` 等 BCP-47 tag,而 OpenAI `language` 字段要 ISO-639-1(`zh` / `en`)。我们的核心
        // 用例是中英混合,自动检测正合适;以后要传就映射 `zh-*` → `zh`、`en-*` → `en`。
        lastFailure = nil

        guard !appSharedSecret.isEmpty else {
            Log.error("[OpenAITranscriber] APP_SHARED_SECRET 未注入,直接失败", category: .ai)
            lastFailure = .sharedSecretMissing
            return nil
        }

        Log.info("[OpenAITranscriber] 开始转写 \(fileURL.lastPathComponent)", category: .ai)

        // 1) 后台读文件 + 拼 multipart。避免 25 MB 阻塞 main actor。
        let prepared: PreparedUpload
        do {
            prepared = try await Task.detached(priority: .userInitiated) {
                try Self.prepareUpload(fileURL: fileURL)
            }.value
        } catch let failure as TranscriptionFailure {
            Log.error("[OpenAITranscriber] 准备上传失败: \(failure)", category: .ai)
            lastFailure = failure
            return nil
        } catch {
            Log.error("[OpenAITranscriber] 准备上传未知错误: \(error)", category: .ai)
            lastFailure = .audioReadFailed
            return nil
        }

        // 2) 发请求。NetworkRetryHelper 的指数退避在网络瞬断时帮我们重试。
        var request = URLRequest(url: backendURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(prepared.boundary)", forHTTPHeaderField: "Content-Type")
        request.applyBackendAuth(sharedSecret: appSharedSecret)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = prepared.body

        struct TranscriptionResponse: Decodable {
            let text: String
        }

        do {
            let text = try await NetworkRetryHelper.performWithRetry { [self] () -> String in
                let (data, response) = try await self.session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard (200...299).contains(http.statusCode) else {
                    throw BackendErrorMapper.error(
                        forStatus: http.statusCode,
                        retryAfter: http.value(forHTTPHeaderField: "Retry-After")
                    )
                }
                let decoded = try jsonDecoder.decode(TranscriptionResponse.self, from: data)
                return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            Log.info("[OpenAITranscriber] 转写成功,长度: \(text.count)", category: .ai)
            return text.isEmpty ? nil : text
        } catch is CancellationError {
            // 用户删了录音 / 视图消失等主动取消;不算失败,不记 lastFailure。
            Log.info("[OpenAITranscriber] 转写被取消", category: .ai)
            return nil
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession 把 Task.cancel() 翻译成 URLError(.cancelled);同上,不算失败。
            Log.info("[OpenAITranscriber] 上传被取消", category: .ai)
            return nil
        } catch let nsError as NSError where nsError.domain == "BackendError" {
            Log.error("[OpenAITranscriber] 服务端错误 \(nsError.code)", category: .ai)
            lastFailure = .serverError(nsError.code)
            return nil
        } catch let urlError as URLError {
            Log.error("[OpenAITranscriber] 网络错误: \(urlError.code.rawValue) \(urlError.localizedDescription)", category: .ai)
            lastFailure = .networkFailed
            return nil
        } catch {
            Log.error("[OpenAITranscriber] 转写失败: \(error)", category: .ai)
            lastFailure = .networkFailed
            return nil
        }
    }

    // MARK: - Multipart Construction

    private struct PreparedUpload {
        let body: Data
        let boundary: String
    }

    /// 在后台 Task 里同步执行:读文件 + 拼 multipart body。
    /// 抛 `TranscriptionFailure`(自定义 case)让上层 catch 直接映射到 lastFailure。
    /// `nonisolated`:从 `Task.detached` 调用,不能继承类的 MainActor 隔离。
    nonisolated private static func prepareUpload(fileURL: URL) throws -> PreparedUpload {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw TranscriptionFailure.audioReadFailed
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else { throw TranscriptionFailure.audioReadFailed }
        guard fileSize <= maxFileBytes else { throw TranscriptionFailure.audioTooLarge }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            Log.error("[OpenAITranscriber] 读音频文件失败: \(error)", category: .ai)
            throw TranscriptionFailure.audioReadFailed
        }

        let boundary = "Lumory-\(UUID().uuidString)"
        let mimeType = mimeTypeFor(fileExtension: fileURL.pathExtension)
        let fileName = fileURL.lastPathComponent

        var body = Data()
        body.appendBoundaryFile(
            boundary: boundary,
            name: "file",
            fileName: fileName,
            mimeType: mimeType,
            content: audioData
        )
        // **故意不附 `model` 字段** — 后端 hardcode `gpt-4o-mini-transcribe`,任何 client 传的
        // model 值都会被服务端忽略(防客户端篡改改更贵模型,trust boundary 在服务端)。这里只附
        // `response_format` 让后端透传给 OpenAI;backend-server.md "转写路由 model hardcode" 段。
        body.appendBoundaryField(boundary: boundary, name: "response_format", value: "json")
        body.appendClosingBoundary(boundary: boundary)
        return PreparedUpload(body: body, boundary: boundary)
    }

    /// AAC m4a → `audio/mp4`(OpenAI 接受);未知扩展名兜底 `application/octet-stream`。
    nonisolated private static func mimeTypeFor(fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "mp3":        return "audio/mpeg"
        case "wav":        return "audio/wav"
        case "webm":       return "audio/webm"
        case "ogg":        return "audio/ogg"
        case "flac":       return "audio/flac"
        default:           return "application/octet-stream"
        }
    }

    // MARK: - Test seams (DEBUG-only)

    #if DEBUG
    /// **Test-only**:暴露 `prepareUpload` 给单测验"25MB 阈值 / missing-file / multipart 形状"。
    /// 返一个 Sendable 元组(避免暴露 private `PreparedUpload` 结构本身)。
    /// 单测验证:body 非空 + boundary 形如 "Lumory-..." + size 阈值。
    nonisolated static func prepareUploadForTesting(fileURL: URL) throws -> (bodyByteCount: Int, boundary: String, mimeType: String) {
        let prepped = try prepareUpload(fileURL: fileURL)
        let mime = mimeTypeFor(fileExtension: fileURL.pathExtension)
        return (bodyByteCount: prepped.body.count, boundary: prepped.boundary, mimeType: mime)
    }

    /// **Test-only**:暴露 25MB 阈值给单测验"刚好超 / 刚好等"边界。
    nonisolated static var maxFileBytesForTesting: Int64 { maxFileBytes }
    #endif
}

// MARK: - multipart helpers

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }

    mutating func appendBoundaryFile(
        boundary: String,
        name: String,
        fileName: String,
        mimeType: String,
        content: Data
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(content)
        appendString("\r\n")
    }

    mutating func appendBoundaryField(boundary: String, name: String, value: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendClosingBoundary(boundary: String) {
        appendString("--\(boundary)--\r\n")
    }
}
