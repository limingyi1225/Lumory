import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum LumoryAdaptivePresentation {
    static let insightsContentMaxWidth: CGFloat = 940
    static let listContentMaxWidth: CGFloat = 900
    static let chatContentMaxWidth: CGFloat = 760
    static let formContentMaxWidth: CGFloat = 720

    nonisolated static func shouldUseExpandedModal(isPad: Bool, horizontalSizeClassIsRegular: Bool) -> Bool {
        isPad || horizontalSizeClassIsRegular
    }
}

private struct LumoryReadableContentModifier: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    func lumoryReadableContent(maxWidth: CGFloat) -> some View {
        modifier(LumoryReadableContentModifier(maxWidth: maxWidth))
    }

    func lumoryAdaptiveModal<ModalContent: View>(
        isPresented: Binding<Bool>,
        interactiveDismissDisabled: Bool = false,
        @ViewBuilder content: @escaping () -> ModalContent
    ) -> some View {
        modifier(LumoryAdaptiveBoolModalModifier(
            isPresented: isPresented,
            interactiveDismissDisabled: interactiveDismissDisabled,
            modalContent: content
        ))
    }

    func lumoryAdaptiveModal<Item: Identifiable, ModalContent: View>(
        item: Binding<Item?>,
        interactiveDismissDisabled: Bool = false,
        @ViewBuilder content: @escaping (Item) -> ModalContent
    ) -> some View {
        modifier(LumoryAdaptiveItemModalModifier(
            item: item,
            interactiveDismissDisabled: interactiveDismissDisabled,
            modalContent: content
        ))
    }
}

// MARK: - iOS 26 sheet 装饰(纯白底)
//
// iPhone 走 .sheet → 套 `Color(.systemBackground)` 纯白底 + 28pt 圆角顶。
//
// **Material 实验史(2026-05-05 一天迭代四次最终回到纯白)**:
//   thin → regular → thick → ultraThick → 纯白。
// 用户每一档都反馈"还是透"+"Settings 子页面 pop 暗一闪"。最终结论:Material 在 iOS 26 sheet
// 上无论多厚都会在 NavigationStack push/pop transition 中间帧短暂透出后方被 dim 的 Home,
// 这是 SwiftUI 内部 transition 渲染顺序导致,Material 档位救不动。**只有 Color 实色完全避开
// 这条路径**(SwiftUI 不会对 Color sheet 做 cross-fade dim)。
//
// 代价:失去 iOS 26 sheet 的玻璃感,sheet 弹出时是传统 iOS 17 之前的纯白卡。
//   - 用户偏好"白的好看"明确表达过(2026-05-05),纯白也消除了"太透"+"闪"两个问题
//   - 但所有走 lumoryAdaptiveModal/lumorySheetDecoration 的 sheet(Insights / AskPast / Settings /
//     Sync diag / Import / Export / Detail 改日期 / Theme picker)都同步变白
//
// iPad regular 仍走 fullScreenCover(那里没有 presentation 装饰 API)。
//
// 用法:任何直接调 `.sheet(...)` 的地方在 closure 末尾加 `.lumorySheetDecoration()`,
// 或经 `lumoryAdaptiveModal` 包装(自动应用)。
extension View {
    func lumorySheetDecoration() -> some View {
        self
            .presentationBackground(sheetBackgroundColor)
            .presentationCornerRadius(28)
    }
}

/// 平台中性的 sheet 实色背景 — iOS 用 UIColor.systemBackground,macOS 直接 .white。
/// 写成 module-level 自由函数避开 SwiftUI Color shorthand 在 macOS 编译歧义。
private var sheetBackgroundColor: Color {
    #if canImport(UIKit)
    return Color(UIColor.systemBackground)
    #else
    return Color.white
    #endif
}

private struct LumoryAdaptiveBoolModalModifier<ModalContent: View>: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let isPresented: Binding<Bool>
    let interactiveDismissDisabled: Bool
    let modalContent: () -> ModalContent

    @ViewBuilder
    func body(content: Content) -> some View {
        if shouldExpand {
            content.fullScreenCover(isPresented: isPresented) {
                modalContent()
                    .interactiveDismissDisabled(interactiveDismissDisabled)
            }
        } else {
            content.sheet(isPresented: isPresented) {
                modalContent()
                    .interactiveDismissDisabled(interactiveDismissDisabled)
                    .lumorySheetDecoration()
            }
        }
    }

    private var shouldExpand: Bool {
        LumoryAdaptivePresentation.shouldUseExpandedModal(
            isPad: currentDeviceIsPad,
            horizontalSizeClassIsRegular: horizontalSizeClass == .regular
        )
    }
}

private struct LumoryAdaptiveItemModalModifier<Item: Identifiable, ModalContent: View>: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let item: Binding<Item?>
    let interactiveDismissDisabled: Bool
    let modalContent: (Item) -> ModalContent

    @ViewBuilder
    func body(content: Content) -> some View {
        if shouldExpand {
            content.fullScreenCover(item: item) { item in
                modalContent(item)
                    .interactiveDismissDisabled(interactiveDismissDisabled)
            }
        } else {
            content.sheet(item: item) { item in
                modalContent(item)
                    .interactiveDismissDisabled(interactiveDismissDisabled)
                    .lumorySheetDecoration()
            }
        }
    }

    private var shouldExpand: Bool {
        LumoryAdaptivePresentation.shouldUseExpandedModal(
            isPad: currentDeviceIsPad,
            horizontalSizeClassIsRegular: horizontalSizeClass == .regular
        )
    }
}

private var currentDeviceIsPad: Bool {
    #if canImport(UIKit)
    UIDevice.current.userInterfaceIdiom == .pad
    #else
    false
    #endif
}
