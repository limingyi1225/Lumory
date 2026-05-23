import Foundation

// MARK: - SSE parsing
//
// 统一的 Server-Sent Events 解析器。三个历史流式入口
// (streamChat / generateReportFromData-onChunk / generateReport-onChunk / chat-stream)
// 都曾 inline 实现 `for try await line in bytes.lines`,规范执行不一致、`[DONE]`
// 识别和截断处理都各搞各的。现在集中到这一处。
//
// 支持 SSE 规范:
//   - `data:` 开头的行累加到当前 event,多条 data 行按 `\n` 拼接
//   - `:` 开头是注释,跳过
//   - `data:` 之后可选一个空格 (规范要求)
//   - 空行 -> dispatch 当前累加的 data
//   - 载荷字面量 `[DONE]` -> 正常结束
//
// 泛型 `T` 是当条 data 的 JSON 结构 (目前都是 OpenAI 的 StreamResponse)。
// 调用方负责把 bytes 喂给我,我负责拆出 Decodable 对象流。
//
// **2026-05 wave11 拆出**:之前内嵌在 OpenAIService.swift,但 NetworkRetryHelper
// 直接依赖 `SSEParser.ParserError`(line 60 那条 isRetryableError 判定),
// 它跟 OpenAI 业务无强耦合,文件命名应该叫 SSEParser 不是 OpenAIService+SSE
// (它是独立 enum,不是 OpenAIService 的 extension)。
@available(iOS 15.0, macOS 12.0, *)
enum SSEParser {
    enum ParserError: LocalizedError {
        case missingDone
        // 故意只带 byte 长度,不存 raw payload —— payload 可能含日记内容 / AI 响应碎片,
        // 进了 LocalizedError 就会被 InsightsEngine / NarrativeReader 当 failure 文案
        // 直接渲染给用户。upstreamError 的 message 由后端 OpenAIStreamErrorEnvelope 提供,
        // 是控制平面的错误描述,不是 SSE 数据内容,所以保留。
        case invalidEvent(byteCount: Int)
        case upstreamError(String)

        var errorDescription: String? {
            switch self {
            case .missingDone:
                return "SSE stream ended before [DONE]."
            case .invalidEvent(let byteCount):
                return "SSE stream contained an invalid event (\(byteCount) bytes)."
            case .upstreamError(let message):
                return message
            }
        }
    }

    /// 解析 SSE 字节流到 Decodable 对象流。遇到 `[DONE]` 或自然结束就 finish;
    /// 网络异常会 throw (caller 自己决定重试 / 吐 truncated 标记)。
    ///
    /// ⚠️ **不要换回 `URLSession.AsyncBytes.lines`。** Apple 实际 ship 的 `AsyncLineSequence`
    /// 在 iOS 26 / 部分版本上**不为空行 yield 空字符串** —— SSEParser 依赖空行触发 dispatch,
    /// 一旦 `.lines` 跳过空行,所有 `data:` event 会粘成一坨,EOF 时 decoder 看到的是
    /// `{json1}\n{json2}\n…` 多个 JSON 拼起来的怪物,直接抛 `invalidEvent`,整段流一字
    /// 未 yield。本地实现按 `\n` 切,顺手吃掉 CRLF 的 `\r`,空行如实 yield `""`。
    static func parse<T: Decodable, Bytes: AsyncSequence>(
        bytes: Bytes,
        type: T.Type,
        decoder: JSONDecoder
    ) -> AsyncThrowingStream<T, Error> where Bytes.Element == UInt8 {
        parse(lineStream: byteLineSequence(bytes: bytes), type: type, decoder: decoder)
    }

    static func parse<T: Decodable>(
        lines: [String],
        type: T.Type,
        decoder: JSONDecoder
    ) -> AsyncThrowingStream<T, Error> {
        let lineStream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish()
        }
        return parse(lineStream: lineStream, type: type, decoder: decoder)
    }

    /// 自己实现的"按 `\n` 切行"。空行 yield 空字符串,CRLF 行尾的 `\r` 吞掉。
    /// 见 `parse(bytes:type:decoder:)` 上方注释:不能用 Apple `AsyncBytes.lines`。
    private static func byteLineSequence<Bytes: AsyncSequence>(
        bytes: Bytes
    ) -> AsyncThrowingStream<String, Error> where Bytes.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var lineBytes: [UInt8] = []
                    for try await byte in bytes {
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        if byte == 0x0A { // \n
                            if lineBytes.last == 0x0D { lineBytes.removeLast() }
                            continuation.yield(String(decoding: lineBytes, as: UTF8.self))
                            lineBytes.removeAll(keepingCapacity: true)
                        } else {
                            lineBytes.append(byte)
                        }
                    }
                    // EOF 时残留的"未终止行"(没有尾随 \n)也 yield 一次,让 SSEParser
                    // 的 EOF 兜底 dispatch 能拿到最后一段 payload(比如服务端只发 `data: [DONE]`
                    // 不带尾随空行的情况)。
                    if !lineBytes.isEmpty {
                        if lineBytes.last == 0x0D { lineBytes.removeLast() }
                        continuation.yield(String(decoding: lineBytes, as: UTF8.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func parse<T: Decodable, Lines: AsyncSequence>(
        lineStream: Lines,
        type: T.Type,
        decoder: JSONDecoder
    ) -> AsyncThrowingStream<T, Error> where Lines.Element == String {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer = ""  // 当前 event 的 data 累加
                    var seenDone = false
                    func dispatch(_ payload: String) throws -> Bool {
                        if payload == "[DONE]" {
                            seenDone = true
                            continuation.finish()
                            return true
                        }
                        guard let data = payload.data(using: .utf8) else {
                            throw ParserError.invalidEvent(byteCount: payload.utf8.count)
                        }
                        do {
                            continuation.yield(try decoder.decode(T.self, from: data))
                        } catch {
                            if let upstreamError = try? decoder.decode(OpenAIStreamErrorEnvelope.self, from: data) {
                                throw ParserError.upstreamError(upstreamError.error.message)
                            }
                            // Defensive parsing: tolerate unknown non-error frames. A proxy or future
                            // upstream field can emit an event this client does not understand; dropping
                            // just that frame preserves already streamed content and lets later valid
                            // frames / [DONE] complete the response.
                            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                                return false
                            }
                            throw ParserError.invalidEvent(byteCount: payload.utf8.count)
                        }
                        return false
                    }
                    for try await line in lineStream {
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        // 注释行 -> 跳过
                        if line.hasPrefix(":") { continue }
                        // 空行 -> dispatch 当前 event
                        if line.isEmpty {
                            if !buffer.isEmpty {
                                if try dispatch(buffer) { return }
                                buffer = ""
                            }
                            continue
                        }
                        // `data:` 开头 -> 追加载荷。规范允许 `data:` 后一个可选空格,
                        // 多行 data 用 `\n` 拼接。
                        if line.hasPrefix("data:") {
                            var payload = Substring(line.dropFirst(5))
                            if payload.first == " " { payload = payload.dropFirst() }
                            if payload == "[DONE]" {
                                if !buffer.isEmpty {
                                    if try dispatch(buffer) { return }
                                    buffer = ""
                                }
                                seenDone = true
                                continuation.finish()
                                return
                            }
                            if !buffer.isEmpty { buffer += "\n" }
                            buffer += String(payload)
                            // 兼容 "data: [DONE]" 单行无空行收尾的实现
                            if buffer == "[DONE]" {
                                seenDone = true
                                continuation.finish()
                                return
                            }
                        }
                        // 其他字段 (id: / event: / retry:) 忽略 —— 目前不需要
                    }
                    // 流正常结束 (到 EOF) 前还有未 flush 的 buffer:尝试 decode 一次
                    if !buffer.isEmpty {
                        if try dispatch(buffer) { return }
                    }
                    if seenDone {
                        continuation.finish()
                    } else {
                        throw ParserError.missingDone
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - SSE stream response (OpenAI Chat Completions)
@available(iOS 15.0, macOS 12.0, *)
struct OpenAIStreamResponse: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }

        var isTruncatedFinish: Bool {
            finishReason == "length" || finishReason == "content_filter"
        }
    }
    let choices: [Choice]

    var hasTruncatedFinish: Bool {
        choices.contains { $0.isTruncatedFinish }
    }
}

@available(iOS 15.0, macOS 12.0, *)
private struct OpenAIStreamErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}
