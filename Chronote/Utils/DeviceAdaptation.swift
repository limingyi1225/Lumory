import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Device Adaptation
//
// iPad 适配用的小工具。原则:
//  - 用 `horizontalSizeClass == .regular` 判定"宽屏布局",而不是 `UIDevice.current.userInterfaceIdiom`。
//    这样 iPad 分屏到 1/3 窄态时会走 compact 分支(视觉和 iPhone 一致),用户拉宽时自动切回 regular。
//  - iPhone Plus/Pro Max 横屏也是 regular 水平——那种情况走宽屏分支也是合理的,不需要特判。
//  - iPad 默认的 form sheet 已经适配良好,这里只补"内容最小尺寸"与"阅读宽度上限"两类。

/// 阅读内容建议的最大宽度。超过这个值正文行太长,眼球回扫负担大,读起来累。
/// 参考 Apple Human Interface Guidelines 对 readable content width 的隐含取值。
enum AdaptiveLayout {
    /// 正文阅读区最大宽度(DiaryDetailView 等长文场景)。
    static let readableContentMaxWidth: CGFloat = 720
    /// iPad sidebar 理想宽度(NavigationSplitView 侧栏)。
    static let sidebarIdealWidth: CGFloat = 380
    static let sidebarMinWidth: CGFloat = 320
    static let sidebarMaxWidth: CGFloat = 460
    /// iPad form sheet 内容最小尺寸——过窄的 sheet 在 iPad 上会压缩 InsightsView 的卡片布局。
    static let sheetMinContentWidth: CGFloat = 560
    static let sheetMinContentHeight: CGFloat = 680
}

extension View {
    /// 把内容居中并限制到可读最大宽度。iPhone 上 `.regular` 水平尺寸类仅在 Plus/Pro Max
    /// 横屏才出现,iPad 全屏 / 2-up 分屏都是 regular——同一逻辑就够用。
    @ViewBuilder
    func readableContentFrame(maxWidth: CGFloat = AdaptiveLayout.readableContentMaxWidth) -> some View {
        modifier(ReadableContentFrameModifier(maxWidth: maxWidth))
    }

    /// 给 iPad 的 `.sheet` 内容撑出一个合理的最小尺寸,避免 form sheet 被内在尺寸压得过窄。
    /// iPhone(compact)上是无操作。
    @ViewBuilder
    func adaptiveSheetFrame(
        minWidth: CGFloat = AdaptiveLayout.sheetMinContentWidth,
        minHeight: CGFloat = AdaptiveLayout.sheetMinContentHeight
    ) -> some View {
        modifier(AdaptiveSheetFrameModifier(minWidth: minWidth, minHeight: minHeight))
    }
}

private struct ReadableContentFrameModifier: ViewModifier {
    let maxWidth: CGFloat
    @Environment(\.horizontalSizeClass) private var hSizeClass

    func body(content: Content) -> some View {
        if hSizeClass == .regular {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            content
        }
    }
}

private struct AdaptiveSheetFrameModifier: ViewModifier {
    let minWidth: CGFloat
    let minHeight: CGFloat

    func body(content: Content) -> some View {
        if Self.isPad {
            // iPad form sheet 默认 ~540×620。sheet 内视图的 hSizeClass 是 compact
            // (540 属于紧凑水平尺寸类),所以这里不能按 size class 判,必须按 idiom 判。
            // 加 minWidth/minHeight 会让 sheet 自动跟着内容撑大,比硬写 .frame(width:) 更鲁棒。
            content.frame(minWidth: minWidth, minHeight: minHeight)
        } else {
            content
        }
    }

    private static var isPad: Bool {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }
}
