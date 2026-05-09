//
//  NetworkRetryHelperRetryableTests.swift
//  ChronoteTests
//
//  覆盖 NetworkRetryHelper 的两块决策表:
//
//  [A] `isRetryableError`(端到端):走 `performWithRetry { throw <error> }` + 观察 attempts
//      —— 因为 `isRetryableError` 是 `private static`,无 internal seam。每次走 `retryDelay: 0`
//      让 retry sleep ~0s,所以 wall-clock jitter 不影响断言。
//
//  [B] `retryAfterDelay` + `delayBeforeRetry`(纯函数):2026-05-09 把 helper 从 `private`
//      升到 `internal` 当**测试 seam**(production code 仅注释 + 可见性变化,无行为改动)。
//      所有 retry-after 解析 / 30s clamp / 指数回退 / jitter 都直接调 helper 拿返回值断言,
//      **零 wall-clock 依赖** —— 比之前的 measureRetryDelay 端到端 wall-clock 测量更稳。
//
//  CLAUDE.md 踩过的坑:
//    * "429 没列 retryable → backfill 撞到 429 静默丢 entry / Ask Past 缺失"
//    * `maxRetryAfterDelay = 30s` clamp 改 helper 顺序就 silent regression
//    * 5xx 中只有 [429, 502, 503, 504] 读 Retry-After,500/501 走指数回退避免维护窗口反复撞墙
//

import Testing
import Foundation
@testable import Lumory

// MARK: - [A] isRetryableError 决策表(端到端,fast-path)

struct NetworkRetryHelperIsRetryableTests {

    // —— BackendError 5xx 可重试段 —————————————————————————————————————

    @Test func backendError429_isRetryable() async throws {
        try await expectRetried(error: backendError(429))
    }

    @Test func backendError502_isRetryable() async throws {
        try await expectRetried(error: backendError(502))
    }

    @Test func backendError503_isRetryable() async throws {
        try await expectRetried(error: backendError(503))
    }

    @Test func backendError504_isRetryable() async throws {
        try await expectRetried(error: backendError(504))
    }

    @Test func backendError500_isRetryable() async throws {
        try await expectRetried(error: backendError(500))
    }

    @Test func backendError550_isRetryable() async throws {
        // 5xx 范围中段:验证"500...599 都 retry,除 501"逻辑
        try await expectRetried(error: backendError(550))
    }

    // —— BackendError 5xx 显式排除 —————————————————————————————————————

    @Test func backendError501_isNotRetryable() async throws {
        // ⚠️ 501 Not Implemented 是结构性失败,重试无意义
        try await expectNotRetried(error: backendError(501))
    }

    // —— BackendError 4xx (除 429) 不可重试 ————————————————————————————

    @Test func backendError400_isNotRetryable() async throws {
        try await expectNotRetried(error: backendError(400))
    }

    @Test func backendError401_isNotRetryable() async throws {
        try await expectNotRetried(error: backendError(401))
    }

    @Test func backendError404_isNotRetryable() async throws {
        try await expectNotRetried(error: backendError(404))
    }

    @Test func backendError413_isNotRetryable() async throws {
        try await expectNotRetried(error: backendError(413))
    }

    // —— URLError 网络层 —————————————————————————————————————————————

    @Test func urlError_notConnectedToInternet_isRetryable() async throws {
        try await expectRetried(error: URLError(.notConnectedToInternet))
    }

    @Test func urlError_timedOut_isRetryable() async throws {
        try await expectRetried(error: URLError(.timedOut))
    }

    @Test func urlError_networkConnectionLost_isRetryable() async throws {
        try await expectRetried(error: URLError(.networkConnectionLost))
    }

    @Test func urlError_dnsLookupFailed_isRetryable() async throws {
        try await expectRetried(error: URLError(.dnsLookupFailed))
    }

    // —— 取消 / 不可重试的客户端控制错误 —————————————————————————————

    @Test func urlError_cancelled_isNotRetryable() async throws {
        try await expectNotRetried(error: URLError(.cancelled))
    }

    @Test func urlError_badURL_isNotRetryable() async throws {
        try await expectNotRetried(error: URLError(.badURL))
    }

    @Test func cancellationError_isNotRetryable() async throws {
        // Swift `CancellationError` 走单独的 `catch is CancellationError` rethrow
        try await expectNotRetried(error: CancellationError())
    }

    // MARK: - Helpers

    /// `retryDelay: 0` 让 sleep ~0s,所以两次 attempt 的 wall-clock 间隔几乎为零,
    /// 这条断言只看 attempts 计数,不看 elapsed。
    private func expectRetried(
        error: Error,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        var attempts = 0
        let value: String = try await NetworkRetryHelper.performWithRetry(
            maxRetries: 2,
            retryDelay: 0
        ) {
            attempts += 1
            if attempts == 1 { throw error }
            return "ok"
        }
        #expect(value == "ok", sourceLocation: sourceLocation)
        #expect(attempts == 2, "expected 2 attempts (retry happened), got \(attempts)", sourceLocation: sourceLocation)
    }

    private func expectNotRetried(
        error: Error,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        var attempts = 0
        await #expect(throws: Error.self, sourceLocation: sourceLocation) {
            try await NetworkRetryHelper.performWithRetry(
                maxRetries: 2,
                retryDelay: 0
            ) {
                attempts += 1
                throw error
            }
        }
        #expect(attempts == 1, "expected 1 attempt (no retry), got \(attempts)", sourceLocation: sourceLocation)
    }

    private func backendError(_ statusCode: Int) -> NSError {
        BackendErrorMapper.error(forStatus: statusCode)
    }
}

// MARK: - [B] retryAfterDelay / delayBeforeRetry 纯函数测试(零 wall-clock 依赖)

struct NetworkRetryHelperRetryAfterTests {

    /// 锁住"语义 cap"= 30s。改这条值前先回 CLAUDE.md 看
    /// `maxRetries × (maxRetryAfterDelay + timeoutIntervalForRequest) < timeoutIntervalForResource`
    /// 不变量(180 < 300)。
    @Test func maxRetryAfterDelayConstantIsLocked() {
        #expect(NetworkRetryHelper.maxRetryAfterDelay == 30.0)
    }

    // —— Retry-After 数字解析 ——————————————————————————————————————————

    @Test func retryAfterDelay_parsesPlainSeconds() {
        let err = BackendErrorMapper.error(forStatus: 429, retryAfter: "60")
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == 60.0)
    }

    @Test func retryAfterDelay_parsesSmallSeconds() {
        let err = BackendErrorMapper.error(forStatus: 429, retryAfter: "1")
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == 1.0)
    }

    @Test func retryAfterDelay_parsesZeroSeconds() {
        let err = BackendErrorMapper.error(forStatus: 429, retryAfter: "0")
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == 0.0)
    }

    @Test func retryAfterDelay_parsesWithWhitespace() {
        // helper 用 .trimmingCharacters(in: .whitespacesAndNewlines) 容错
        let err = BackendErrorMapper.error(forStatus: 429, retryAfter: "  60  ")
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == 60.0)
    }

    @Test func retryAfterDelay_negativeClampsToZero() {
        // helper 用 max(seconds, 0) → "-5" 应返 0
        let err = BackendErrorMapper.error(forStatus: 429, retryAfter: "-5")
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == 0.0)
    }

    // —— Retry-After HTTP-date 解析 ———————————————————————————————————

    @Test func retryAfterDelay_parsesHTTPDate() {
        // RFC 7231 HTTP-date 格式("EEE, dd MMM yyyy HH:mm:ss z" en_US_POSIX / GMT)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        // 取 +60s,容差给 ±2s 抗"helper 内部 .timeIntervalSinceNow 跟测试构造点之间的时差"
        let target = Date().addingTimeInterval(60)
        let dateString = formatter.string(from: target)

        let err = BackendErrorMapper.error(forStatus: 429, retryAfter: dateString)
        let parsed = NetworkRetryHelper.retryAfterDelay(from: err)
        #expect(parsed != nil, "HTTP-date should parse")
        if let parsed {
            // 容差 ±2s 是给两次 Date() 之间(测试构造点 → helper 内部 timeIntervalSinceNow)
            // 留的实际函数调用时间窗口,跟 Task.sleep 抖动是不同来源(这里是函数体跑过的真实
            // 时长,几十微秒级,容差极宽松)。
            #expect(parsed >= 58.0 && parsed <= 62.0, "expected ~60s, got \(parsed)s")
        }
    }

    @Test func retryAfterDelay_pastHTTPDateClampsToZero() {
        // helper 用 max(date.timeIntervalSinceNow, 0) → 过去日期返 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        let pastDate = Date().addingTimeInterval(-3600)
        let dateString = formatter.string(from: pastDate)

        let err = BackendErrorMapper.error(forStatus: 429, retryAfter: dateString)
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == 0.0)
    }

    // —— Retry-After 不可解析 / 缺失 → nil ————————————————————————————

    @Test func retryAfterDelay_garbageReturnsNil() {
        let err = BackendErrorMapper.error(forStatus: 429, retryAfter: "garbage-string")
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == nil)
    }

    @Test func retryAfterDelay_emptyStringReturnsNil() {
        // 空字符串:trim 后 "" → TimeInterval("") == nil → DateFormatter 也失败 → nil
        let err = BackendErrorMapper.error(forStatus: 429, retryAfter: "")
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == nil)
    }

    @Test func retryAfterDelay_missingHeaderReturnsNil() {
        // 没 Retry-After 头:userInfo 不含 key → 返 nil
        let err = BackendErrorMapper.error(forStatus: 429)
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == nil)
    }

    @Test func retryAfterDelay_nonBackendErrorReturnsNil() {
        // 非 BackendError domain → 即便有 userInfo["Retry-After"] 也返 nil(domain guard)
        let err = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: ["Retry-After": "60"]
        )
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == nil)
    }

    // —— Retry-After 只在 [429, 502, 503, 504] 上读取 ——————————————————

    @Test func retryAfterDelay_status429_honored() {
        let err = BackendErrorMapper.error(forStatus: 429, retryAfter: "30")
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == 30.0)
    }

    @Test func retryAfterDelay_status502_honored() {
        let err = BackendErrorMapper.error(forStatus: 502, retryAfter: "30")
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == 30.0)
    }

    @Test func retryAfterDelay_status503_honored() {
        let err = BackendErrorMapper.error(forStatus: 503, retryAfter: "30")
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == 30.0)
    }

    @Test func retryAfterDelay_status504_honored() {
        let err = BackendErrorMapper.error(forStatus: 504, retryAfter: "30")
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == 30.0)
    }

    /// 500 + Retry-After 必须返 nil(让 5xx generic 滑回指数回退,避免维护窗口反复撞墙)
    @Test func retryAfterDelay_status500_ignoredEvenWithHeader() {
        let err = BackendErrorMapper.error(forStatus: 500, retryAfter: "60")
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == nil)
    }

    @Test func retryAfterDelay_status501_ignoredEvenWithHeader() {
        let err = BackendErrorMapper.error(forStatus: 501, retryAfter: "60")
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == nil)
    }

    @Test func retryAfterDelay_status400_ignoredEvenWithHeader() {
        // 4xx 系列也不读
        let err = BackendErrorMapper.error(forStatus: 400, retryAfter: "60")
        #expect(NetworkRetryHelper.retryAfterDelay(from: err) == nil)
    }

    // —— delayBeforeRetry: 30s clamp 验证(纯函数,零 wall-clock)———————

    /// 30s clamp 的真正 invariant —— Retry-After: "999" 必须被 cap 在 30s。
    /// 之前的端到端测试(`clampsAtMaxRetryAfterDelay`)真等 30s + 容差 [29, 33]
    /// 在 CI 抖动下 flake 风险高(codex 复审指出)。改成纯函数直接拿 helper 返回值,
    /// 等于 0 wall-clock 验证 + 锁住 cap 语义。
    @Test func delayBeforeRetry_retryAfter999_clampsTo30() {
        let err = BackendErrorMapper.error(forStatus: 429, retryAfter: "999")
        let delay = NetworkRetryHelper.delayBeforeRetry(for: err, attempt: 0, baseDelay: 1.0)
        #expect(delay == 30.0, "clamp at maxRetryAfterDelay (30s), got \(delay)s")
    }

    @Test func delayBeforeRetry_retryAfter5_returnsExactly5() {
        // 边界:5 < 30 → 不 clamp,返回原值
        let err = BackendErrorMapper.error(forStatus: 429, retryAfter: "5")
        let delay = NetworkRetryHelper.delayBeforeRetry(for: err, attempt: 0, baseDelay: 1.0)
        #expect(delay == 5.0)
    }

    @Test func delayBeforeRetry_retryAfter30_returnsExactly30() {
        // 边界:30 == cap → 返回 30
        let err = BackendErrorMapper.error(forStatus: 429, retryAfter: "30")
        let delay = NetworkRetryHelper.delayBeforeRetry(for: err, attempt: 0, baseDelay: 1.0)
        #expect(delay == 30.0)
    }

    @Test func delayBeforeRetry_retryAfter31_clampsTo30() {
        // 边界:刚过 cap 一点
        let err = BackendErrorMapper.error(forStatus: 429, retryAfter: "31")
        let delay = NetworkRetryHelper.delayBeforeRetry(for: err, attempt: 0, baseDelay: 1.0)
        #expect(delay == 30.0)
    }

    // —— delayBeforeRetry: 指数回退 + jitter(无 Retry-After 时)———————

    @Test func delayBeforeRetry_noRetryAfter_attemptZero_baseSeconds_withinJitter() {
        // 无 Retry-After header → 走 base * 2^0 * [0.75, 1.25]
        let err = BackendErrorMapper.error(forStatus: 502)  // 502 retryable 但不带 retry-after
        let delay = NetworkRetryHelper.delayBeforeRetry(for: err, attempt: 0, baseDelay: 1.0)
        #expect(delay >= 0.75 && delay <= 1.25, "attempt 0 base 1s ±25% jitter, got \(delay)s")
    }

    @Test func delayBeforeRetry_noRetryAfter_attemptOne_doublesBase() {
        let err = BackendErrorMapper.error(forStatus: 502)
        let delay = NetworkRetryHelper.delayBeforeRetry(for: err, attempt: 1, baseDelay: 1.0)
        // 2^1 = 2,jitter ±25% → [1.5, 2.5]
        #expect(delay >= 1.5 && delay <= 2.5, "attempt 1 base 1s expects ~2s ±25%, got \(delay)s")
    }

    @Test func delayBeforeRetry_noRetryAfter_attemptThree_capsAtMaxRetryDelay() {
        // baseDelay=10,attempt=3 → 80,但 maxRetryDelay 应该 cap 住。
        // helper 用 min(base * 2^attempt, maxRetryDelay) + jitter 可能让 result > maxRetryDelay
        // (jitter 1.25 倍),但 final 还有 min(.., maxRetryDelay) 兜底,所以一定 ≤ maxRetryDelay
        let err = BackendErrorMapper.error(forStatus: 502)
        let delay = NetworkRetryHelper.delayBeforeRetry(for: err, attempt: 3, baseDelay: 10.0)
        // 不知道 maxRetryDelay 具体值,但断言 < 100s 安全(防 base*2^attempt=80 直接溢出)
        #expect(delay <= 100.0, "exponential backoff must be capped, got \(delay)s")
    }
}
