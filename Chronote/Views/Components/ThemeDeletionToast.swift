import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum ThemeDeletionToast {
    static func show(
        name: String,
        undoPayload: ThemeManagementService.ThemeDeletionUndoPayload?,
        onRestored: @escaping @MainActor @Sendable () async -> Void
    ) {
        let message = String(format: NSLocalizedString("已删除主题「%@」", comment: "Delete toast"), name)
        guard let undoPayload else {
            LumoryToastCenter.shared.show(message, severity: .success)
            return
        }
        LumoryToastCenter.shared.show(
            message,
            severity: .success,
            duration: EntryDeletionUndoService.undoWindow,
            action: LumoryToastCenter.Action(
                label: NSLocalizedString("撤销", comment: "Undo delete action")
            ) {
                Task { @MainActor in
                    let outcome = await ThemeManagementService.shared.restoreDeletedTheme(undoPayload)
                    if outcome.succeeded {
                        #if canImport(UIKit)
                        HapticManager.shared.notification(.success)
                        #endif
                        await onRestored()
                    } else {
                        #if canImport(UIKit)
                        HapticManager.shared.notification(.error)
                        #endif
                        LumoryToastCenter.shared.show(
                            NSLocalizedString("撤销失败,请稍后再试。", comment: "Undo theme delete failed"),
                            severity: .warning
                        )
                    }
                }
            }
        )
    }
}
