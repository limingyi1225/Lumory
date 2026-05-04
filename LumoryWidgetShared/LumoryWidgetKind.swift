import Foundation

/// Widget kind 字符串的唯一真源。主 App 端 `WidgetCenter.reloadTimelines(ofKind:)`
/// 和 widget 端 `StaticConfiguration(kind:)` 都引用这里 —— 两边写错就 silent
/// no-op(reload 找不到 widget,系统不报错)。
///
/// **不要**让主 App 直接引 widget target 里的 `QuickWriteWidget.kind`:
/// 那会形成主 App → widget target 的反向依赖,Xcode 会拒绝编译。
enum LumoryWidgetKind {
    static let quickWrite = "Mingyi.Lumory.QuickWrite"
}
