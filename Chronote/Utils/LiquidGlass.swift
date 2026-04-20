import SwiftUI

// MARK: - Liquid Glass View Extensions

extension View {
    /// iOS 26 Liquid Glass card background. Used for input container and
    /// timeline cards. Optional `tint` for mood-aware surfaces.
    /// Set `interactive: true` only for tap-target cards (list rows, CTA cards)
    /// — Apple's guidance reserves `.interactive()` for elements that respond
    /// to touch/pointer.
    func liquidGlassCard(
        cornerRadius: CGFloat = 16,
        tint: Color? = nil,
        tintStrength: Double = 0.16,
        interactive: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        var style: Glass = .regular
        if let tint {
            style = style.tint(tint.opacity(tintStrength))
        }
        if interactive {
            style = style.interactive()
        }
        return self.glassEffect(style, in: shape)
    }

    /// Capsule-shaped glass (used by spectrum and pill buttons).
    func liquidGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        var style: Glass = .regular
        if let tint {
            style = style.tint(tint.opacity(0.18))
        }
        if interactive {
            style = style.interactive()
        }
        return self.glassEffect(style, in: Capsule())
    }

    /// Insights dashboard module card — consistent corner radius + subtle shadow.
    func insightsCard(cornerRadius: CGFloat = 18) -> some View {
        self.liquidGlassCard(cornerRadius: cornerRadius)
            .shadow(color: Color.primary.opacity(0.05), radius: 8, x: 0, y: 3)
    }

    /// Left accent bar — a narrow colored strip clipped inside the card shape.
    @ViewBuilder
    func moodAccentBar(_ color: Color, cornerRadius: CGFloat = 16, visible: Bool = true) -> some View {
        if visible {
            self.overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.95), color.opacity(0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 6)
                    .shadow(color: color.opacity(0.5), radius: 4, y: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
        }
    }
}
