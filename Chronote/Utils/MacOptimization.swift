import SwiftUI
#if targetEnvironment(macCatalyst)
import AppKit
#endif

// MARK: - Platform Detection
extension UIDevice {
    static var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }
}

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
        if let windowScene = connectedScenes.first as? UIWindowScene {
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 800, height: 600)
            windowScene.sizeRestrictions?.maximumSize = CGSize(width: 1400, height: 1000)
        }
    }
}

// Helper for accessing NSToolbar from UIKit
class MacToolbarHelper {
    static func addToolbarItems(to scene: UIWindowScene) {
        #if targetEnvironment(macCatalyst)
        if let titlebar = scene.titlebar {
            let toolbar = NSToolbar(identifier: "MainToolbar")
            toolbar.delegate = MacToolbarDelegate.shared
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconOnly
            titlebar.toolbar = toolbar
        }
        #endif
    }
}

class MacToolbarDelegate: NSObject, NSToolbarDelegate {
    static let shared = MacToolbarDelegate()
    
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            .toggleSidebar,
            .flexibleSpace,
            NSToolbarItem.Identifier("new-entry"),
            NSToolbarItem.Identifier("calendar"),
            .flexibleSpace,
            NSToolbarItem.Identifier("settings")
        ]
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }
    
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case NSToolbarItem.Identifier("new-entry"):
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("新日记", comment: "New Entry")
            if let image = UIImage(systemName: "plus") {
                item.image = image
            }
            item.target = self
            item.action = #selector(newEntryAction)
            return item
            
        case NSToolbarItem.Identifier("calendar"):
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("日历", comment: "Calendar")
            if let image = UIImage(systemName: "calendar") {
                item.image = image
            }
            item.target = self
            item.action = #selector(calendarAction)
            return item
            
        case NSToolbarItem.Identifier("settings"):
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("设置", comment: "Settings")
            if let image = UIImage(systemName: "gearshape") {
                item.image = image
            }
            item.target = self
            item.action = #selector(settingsAction)
            return item
            
        default:
            return nil
        }
    }
    
    @objc private func newEntryAction() {
        NotificationCenter.default.post(name: .macNewEntry, object: nil)
    }
    
    @objc private func calendarAction() {
        NotificationCenter.default.post(name: .macShowCalendar, object: nil)
    }
    
    @objc private func settingsAction() {
        NotificationCenter.default.post(name: .macShowSettings, object: nil)
    }
}

// Notification names for Mac toolbar actions
extension Notification.Name {
    static let macNewEntry = Notification.Name("macNewEntry")
    static let macShowCalendar = Notification.Name("macShowCalendar")
    static let macShowSettings = Notification.Name("macShowSettings")
}
#endif

// MARK: - Mac-optimized UI Components
struct MacAdaptiveLayout<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        if UIDevice.isMac {
            HStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
        }
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
        if UIDevice.isMac {
            return AnyView(self.modifier(MacKeyboardShortcuts()))
        } else {
            return AnyView(self)
        }
    }
}

// Mac-optimized sidebar
struct MacSidebar<Content: View>: View {
    let content: Content
    @Binding var isVisible: Bool
    
    init(isVisible: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self._isVisible = isVisible
        self.content = content()
    }
    
    var body: some View {
        if UIDevice.isMac {
            HStack(spacing: 0) {
                if isVisible {
                    content
                        .frame(width: MacOptimizedSpacing.sidebarWidth)
                        .background(Color(.systemBackground))
                        .transition(.move(edge: .leading))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isVisible)
        } else {
            content
        }
    }
}

// Mac-optimized content area
struct MacContentArea<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        if UIDevice.isMac {
            content
                .padding(.horizontal, MacOptimizedSpacing.mainContentPadding)
                .padding(.top, MacOptimizedSpacing.toolbarHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
        } else {
            content
        }
    }
}

// Mac hover effects
struct MacHoverEffect: ViewModifier {
    @State private var isHovered = false
    
    func body(content: Content) -> some View {
        if UIDevice.isMac {
            content
                .scaleEffect(isHovered ? 1.02 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: isHovered)
                .onHover { hovering in
                    isHovered = hovering
                }
        } else {
            content
        }
    }
}

extension View {
    func macHoverEffect() -> some View {
        self.modifier(MacHoverEffect())
    }
}