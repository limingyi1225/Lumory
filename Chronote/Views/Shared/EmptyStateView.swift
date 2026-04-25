import SwiftUI

// MARK: - EmptyStateView
//
// 统一的空状态组件：列表无数据 / 搜索无结果 / 日历空白日都复用。
// 保持和品牌一致的留白节奏：顶部图标 → 标题 → 副标题。

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String?

    init(
        systemImage: String,
        title: String,
        message: String? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.secondary)
                .padding(.bottom, 2)

            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message ?? "")")
    }
}
