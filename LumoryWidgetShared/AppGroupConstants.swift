import Foundation

/// 主 App 与 widget extension 共享的常量。
/// 这个文件**只能** import Foundation —— shared sources 同时编进两个 target,
/// widget 进程没有 UIKit / CoreData / WidgetKit 上下文,任何额外依赖都会污染边界。
enum AppGroup {
    /// 与 Lumory.entitlements / LumoryWidgets.entitlements 中的 application-groups 一致。
    /// 改这里要同步改两个 entitlements 文件 + Developer Portal 的 App Group 注册。
    static let identifier = "group.Mingyi.Lumory"

    /// Snapshot JSON 在 App Group 容器内的相对路径(从容器根算起)。
    /// 放 Application Support 而不是 Caches —— Caches 会被系统在低存储时清掉,
    /// snapshot 是 widget 唯一可读数据源,不能丢。
    static let snapshotRelativePath = "Library/Application Support/Widget/snapshot.json"

    /// App Group UserDefaults —— 主 App + widget extension 共用的 key/value store。
    /// **用途**:用户在主 App 设置的 `appLanguage` 写到这里,widget 读这里决定渲染哪一档语言,
    /// 否则 widget 只能跟系统 locale 走(主 App 选中文 + 设备英文 → widget 显示英文,跟主 App 不一致)。
    /// **fallback**:App Group entitlement 缺失或 Developer Portal 没注册时返回 `.standard`,
    /// widget 端读不到(其本身没 entitlement 时 standard 跟主 App 不通),但主 App 自己仍能跑,不崩。
    static var userDefaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}
