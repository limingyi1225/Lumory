import SwiftUI

// MARK: - FlowLayout
//
// 简单的行内流式布局：把子视图按次序从左到右排列，溢出自动换行。
// 用于主题 chip 这种长度不一的标签列表。

@available(iOS 16.0, macOS 13.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(in: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height + spacing } - (rows.isEmpty ? 0 : spacing)
        let width = rows.map { $0.width }.max() ?? 0
        return CGSize(width: min(width, maxWidth), height: max(height, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(in: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = item.subview.sizeThatFits(.unspecified)
                item.subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct RowItem {
        let subview: LayoutSubview
        let size: CGSize
    }
    private struct Row {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(in maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            var current = rows[rows.count - 1]
            let prospective = current.width + (current.items.isEmpty ? 0 : spacing) + size.width
            if prospective > maxWidth && !current.items.isEmpty {
                rows.append(Row(items: [RowItem(subview: subview, size: size)], width: size.width, height: size.height))
            } else {
                current.items.append(RowItem(subview: subview, size: size))
                current.width = prospective
                current.height = max(current.height, size.height)
                rows[rows.count - 1] = current
            }
        }
        return rows
    }
}
