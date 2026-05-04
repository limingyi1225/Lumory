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
}
