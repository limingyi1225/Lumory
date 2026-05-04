import Foundation

/// `lumory://...` deep-link 解析与分发。
///
/// **纯解析 / side-effect 分离**:`route(for:)` 是纯函数,单测覆盖,
/// `handle(_:)` 才触发 `ReminderNotificationRouter` 全局状态。
/// 测试只测 `route(for:)`,不污染 router state。
enum LumoryURLRoute: Equatable {
    case compose
}

enum LumoryURLRouter {
    /// `lumory://compose` → `.compose`。**`compose` 是 URL host,不是 path** ——
    /// `URL(string: "lumory://compose").host == "compose"`,常见踩坑点。
    /// 不识别 → nil(future 加新 host 在这里扩)。
    static func route(for url: URL) -> LumoryURLRoute? {
        guard url.scheme?.lowercased() == "lumory" else { return nil }
        switch url.host?.lowercased() {
        case "compose":
            return .compose
        default:
            return nil
        }
    }

    static func handle(_ url: URL) {
        guard let route = route(for: url) else { return }
        switch route {
        case .compose:
            ReminderNotificationRouter.shared.requestComposeFocus()
        }
    }
}
