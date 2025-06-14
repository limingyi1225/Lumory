import SwiftUI
#if targetEnvironment(macCatalyst)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Optimized Platform Detection
struct PlatformInfo {
    // Cache the platform check result to avoid repeated conditional compilation checks
    static let isMacCatalyst: Bool = {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }()

    // Optimized device type checking
    static let deviceType: DeviceType = {
        #if targetEnvironment(macCatalyst)
        return .macCatalyst
        #elseif os(iOS)
        return .iOS
        #else
        return .macOS
        #endif
    }()
}

enum DeviceType {
    case iOS
    case macCatalyst
    case macOS
}

#if canImport(UIKit)
extension UIDevice {
    static var isMac: Bool {
        PlatformInfo.isMacCatalyst
    }
}
#endif

// MARK: - Mac-specific UI Helpers
struct MacOptimizedSpacing {
    static let sidebarWidth: CGFloat = 280
    static let mainContentPadding: CGFloat = 24
    static let toolbarHeight: CGFloat = 52
    static let listRowSpacing: CGFloat = 8
    static let cardPadding: CGFloat = 16
}

// MARK: - Mac Window Management
#if targetEnvironment(macCatalyst)
extension UIApplication {
    func configureForMac() {
        // Configure window properties for better Mac experience
        guard let windowScene = connectedScenes.first as? UIWindowScene else { return }
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 1200, height: 700)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 2000, height: 1400)
    }
}

// Simplified toolbar helper to avoid startup issues and NSToolbarItemGroup warnings
class MacToolbarHelper {
    static func addToolbarItems(to scene: UIWindowScene) {
        // Toolbar configuration is now disabled to avoid NSToolbarItemGroup selection mode warnings
        // NavigationSplitView handles toolbar management automatically
        print("[MacToolbarHelper] Toolbar configuration disabled - using NavigationSplitView built-in toolbar")
    }
}
#endif

// MARK: - Mac-optimized UI Components with Performance Improvements
struct MacAdaptiveLayout<Content: View>: View {
    let content: Content
    private let isMacCatalyst = PlatformInfo.isMacCatalyst

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Mac-specific button styles
struct MacToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(configuration.isPressed ? .secondary : .primary)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// Mac keyboard shortcuts
struct MacKeyboardShortcuts: ViewModifier {
    func body(content: Content) -> some View {
        content
            .keyboardShortcut("n", modifiers: .command) // New entry
            .keyboardShortcut("1", modifiers: .command) // Focus on main view
            .keyboardShortcut(",", modifiers: .command) // Settings
    }
}

extension View {
    func macKeyboardShortcuts() -> some View {
        #if targetEnvironment(macCatalyst)
        self.modifier(MacKeyboardShortcuts())
        #else
        self
        #endif
    }
}

// Mac-optimized sidebar with performance improvements
struct MacSidebar<Content: View>: View {
    let content: Content
    @Binding var isVisible: Bool
    #if canImport(UIKit)
    private let backgroundColor = Color(UIColor.systemBackground)
    #else
    private let backgroundColor = Color.clear
    #endif

    init(isVisible: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self._isVisible = isVisible
        self.content = content()
    }

    var body: some View {
        #if targetEnvironment(macCatalyst)
        HStack(spacing: 0) {
            if isVisible {
                content
                    .frame(width: MacOptimizedSpacing.sidebarWidth)
                    .background(backgroundColor)
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        #else
        content
        #endif
    }
}

// Mac-optimized content area with performance improvements
struct MacContentArea<Content: View>: View {
    let content: Content
    #if canImport(UIKit)
    private let backgroundColor = Color(UIColor.systemBackground)
    #else
    private let backgroundColor = Color.clear
    #endif

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        #if targetEnvironment(macCatalyst)
        content
            .padding(.horizontal, MacOptimizedSpacing.mainContentPadding)
            .padding(.top, MacOptimizedSpacing.toolbarHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backgroundColor)
        #else
        content
        #endif
    }
}

// Mac hover effects
struct MacHoverEffect: ViewModifier {
    @State private var isHovered = false
    
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
        #else
        content
        #endif
    }
}

extension View {
    func macHoverEffect() -> some View {
        modifier(MacHoverEffect())
    }
}