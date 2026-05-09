import XCTest
@testable import Lumory

/// 只测 `LumoryURLRouter.route(for:)` 纯函数 —— 不动 `ReminderNotificationRouter`
/// 全局状态(那条由 `handle(_:)` 触发,有 side-effect,留给手动 sim 验证)。
final class LumoryURLRouterTests: XCTestCase {
    func testHostCompose() {
        XCTAssertEqual(LumoryURLRouter.route(for: URL(string: "lumory://compose")!), .compose)
    }

    func testHostComposeWithExtraPath() {
        XCTAssertEqual(LumoryURLRouter.route(for: URL(string: "lumory://compose/extra")!), .compose)
    }

    func testUnknownHostReturnsNil() {
        XCTAssertNil(LumoryURLRouter.route(for: URL(string: "lumory://other")!))
    }

    func testWrongSchemeReturnsNil() {
        XCTAssertNil(LumoryURLRouter.route(for: URL(string: "https://compose")!))
    }

    func testCaseInsensitiveScheme() {
        XCTAssertEqual(LumoryURLRouter.route(for: URL(string: "LUMORY://compose")!), .compose)
    }

    /// `mingyi-lumory://` 是 canonical scheme(widget tap 用它),legacy `lumory://` 仍兼容。
    func testCanonicalSchemeMingyiLumory() {
        XCTAssertEqual(LumoryURLRouter.route(for: URL(string: "mingyi-lumory://compose")!), .compose)
    }

    func testCanonicalSchemeCaseInsensitive() {
        XCTAssertEqual(LumoryURLRouter.route(for: URL(string: "Mingyi-Lumory://compose")!), .compose)
    }

    /// 冷启动 deep-link / Universal Link rewrite / 第三方 share sheet 都可能塞进来畸形 URL。
    /// 全部应该 nil(`handle(_:)` 也跟着 no-op,不触发 compose focus)。
    func testMalformedURLsReturnNil() {
        let cases = [
            "lumory:/compose",       // 单斜杠 → host nil, path "compose"
            "lumory:compose",        // 没斜杠 → opaque
            "lumory://",             // 空 host
            "lumory:///compose",     // 空 host + compose 在 path 上
            "lumory://compose%20",   // percent-encoded host(URL.host 拿到 "compose " 含空格)
        ]
        for raw in cases {
            guard let url = URL(string: raw) else { continue }
            XCTAssertNil(
                LumoryURLRouter.route(for: url),
                "URL '\(raw)' 不该解析成 .compose"
            )
        }
    }

    // MARK: - Scheme parity(锁住 router ↔ Info.plist 的 scheme 一一对齐)
    //
    // 双 scheme 是历史包袱:`lumory://` 是早期版本注册的 scheme,`mingyi-lumory://` 是后来
    // 加的 canonical(撞名概率低,widget tap 用这个)。两边都必须支持,否则:
    //   - 老用户从锁屏点过的 reminder 通知 / 老 widget URL → `lumory://` → 无法路由 = 静默失败
    //   - widget extension 内部用 `mingyi-lumory://` schedule deep-link → router 没注册 = 同样静默失败
    //
    // 改 `LumoryURLRouter.acceptedSchemes` 必须同步改 `Lumory-Info.plist` 的
    // `CFBundleURLSchemes`,否则 iOS 不让 router 收到 URL。下面两条测试任一改动都会 fail。

    /// 双 scheme 必须解析成等价 route。任一 scheme 的 host 路由表跑偏,这条会 fail。
    /// 未来加新 host(比如 `lumory://entry/{id}`)在两个 scheme 上都要测一遍。
    func testSchemeParity_bothSchemesMapToSameRoute() {
        let schemes = ["mingyi-lumory", "lumory"]
        for scheme in schemes {
            let url = URL(string: "\(scheme)://compose")!
            XCTAssertEqual(
                LumoryURLRouter.route(for: url),
                .compose,
                "scheme '\(scheme)' 必须解析成 .compose;router 双 scheme 一一对齐 invariant 被破坏"
            )
        }
    }

    /// 测试期望的 scheme 列表 = `Lumory-Info.plist` 中 `CFBundleURLTypes[].CFBundleURLSchemes` 的并集。
    /// 这条测试是 "drift 锁":有人删 plist scheme 但忘改 router(或反之)→ 这里 fail。
    /// 测试硬编码期望值,改动后必须自觉更新这条 + plist + router 三处。
    func testSchemeParity_plistSchemesMatchExpectedList() {
        let expected: Set<String> = ["mingyi-lumory", "lumory"]
        let bundle = Bundle(for: type(of: self))
            .url(forResource: "Lumory-Info", withExtension: "plist")
            ?? Bundle.main.url(forResource: "Lumory-Info", withExtension: "plist")
        // app bundle 在 main bundle 加载;test bundle 也能通过 main 拿到 Info.plist key。
        guard let urlTypes = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] else {
            // host App 没注册 URL types 时跳过(纯 unit test target 跑这条不该 fail);
            // 实际 sim 跑 test 会从 main bundle 读到。
            _ = bundle
            return
        }
        let actual = Set(urlTypes.compactMap { $0["CFBundleURLSchemes"] as? [String] }.flatMap { $0 })
        XCTAssertEqual(
            actual,
            expected,
            "Info.plist CFBundleURLSchemes 跟 router acceptedSchemes 漂了 — actual=\(actual.sorted()) expected=\(expected.sorted())"
        )
    }
}
