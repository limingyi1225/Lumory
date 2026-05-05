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
