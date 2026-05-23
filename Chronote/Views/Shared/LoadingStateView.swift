import SwiftUI

struct LoadingStateView: View {
    enum Size {
        case inline
        case compact
    }

    let message: String?
    let size: Size

    init(_ message: String? = nil, size: Size = .inline) {
        self.message = message
        self.size = size
    }

    var body: some View {
        HStack(spacing: spacing) {
            ProgressView()
                .controlSize(controlSize)
            if let message, !message.isEmpty {
                Text(message)
                    .font(font)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var spacing: CGFloat {
        switch size {
        case .inline: 6
        case .compact: 8
        }
    }

    private var controlSize: ControlSize {
        switch size {
        case .inline: .regular
        case .compact: .small
        }
    }

    private var font: Font {
        switch size {
        case .inline: .subheadline
        case .compact: .caption
        }
    }
}
