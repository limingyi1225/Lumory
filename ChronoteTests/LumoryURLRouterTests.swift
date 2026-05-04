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
}
