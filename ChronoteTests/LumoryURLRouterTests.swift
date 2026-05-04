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
}
