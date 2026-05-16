//
//  MockURLProtocol.swift
//  ChronoteTests
//
//  Test-only URLProtocol that intercepts URLSession requests and returns
//  stubbed responses. Wired into a session via:
//
//      let session = MockURLProtocol.makeSession()
//      MockURLProtocol.requestHandler = { request in
//          (HTTPURLResponse(...), responseData)
//      }
//
//  设计取舍:
//   - **per-test handler closure(`requestHandler`)而非 stub table by URL**:
//     测试要按"返 200/返 500/抛 URLError"切换响应,closure 灵活;按 URL stub 在
//     单 endpoint 项目里反而冗余。
//   - **body capture 读 httpBodyStream**:URLSession 把 `request.httpBody` 转成
//     `httpBodyStream`,在 URLProtocol 截获时 `httpBody` 为 nil。要验证 JSON
//     payload schema(Phase 1.2 的契约 lock-in)必须读 stream。
//   - **`nonisolated(unsafe)` static 状态 + tearDown 必清**:URLProtocol 是 Foundation
//     instantiate 的,没法注入 instance state;只能用 static。**tearDown 不重置
//     就会泄漏到下一条测试**,因此提供 `reset()` 强制约定。
//
//  ⚠️ 不要把 `MockURLProtocol` 放到 protocolClasses 里又同时跑真网络测试 —— 全局
//  注册的 URLProtocol 会拦截**所有** URLSession 请求,真网络测试会被一并拦下。
//  用 `makeSession()` 拿到只挂 MockURLProtocol 的 ephemeral session,跟生产 session 隔离。

import Foundation

final class MockURLProtocol: URLProtocol {

    /// 每条测试 setUp 设一次,tearDown 必须清。handler 在 URLSession 内部 queue 上调用。
    /// 返回 (response, body) 元组,或 throw 模拟网络错误(典型 URLError)。
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Inspection seam:每个被拦截的请求 + 读出的 body data 追加在这里(顺序保证)。
    /// 测试可以 assert payload schema / 请求次数等。tearDown 时 reset()。
    nonisolated(unsafe) static var recordedRequests: [(request: URLRequest, body: Data?)] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let capturedBody = Self.readBody(from: request)
        Self.recordedRequests.append((request: request, body: capturedBody))

        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "MockURLProtocol",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No requestHandler registered for \(request.url?.absoluteString ?? "?")"]
            ))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No-op — sync stub completes in startLoading.
    }

    /// 必在每条测试 tearDown 调,清掉 handler + recorded list。漏调 → handler 泄漏到
    /// 下一条测试 → 难以诊断的 false positive / false negative。
    static func reset() {
        requestHandler = nil
        recordedRequests = []
    }

    // MARK: - Body capture

    /// URLSession 把 `request.httpBody` 转成 `httpBodyStream`,所以 URLProtocol 拦截时
    /// `httpBody` 通常为 nil。读 stream 拿原始字节。
    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 {
                // stream error 与 EOF 同处理会让测试 silently 拿到 truncated body。
                // 返 nil 让 recordedRequests 显式标记"capture 失败",assertion 会立刻 fail。
                // (2026-05-16 superreview round 3 P2 #3 修)
                return nil
            }
            if read == 0 { break }  // EOF
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: - Session factory

    /// 返回一个**只挂 MockURLProtocol 的 ephemeral session**,跟生产 sharedRetrySession 隔离。
    /// 每条测试拿一个新的 session,session 自身不复用 —— 防 connection cache 干扰。
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
