import SwiftUI

// MARK: - View Performance Helpers

extension View {
    /// 统一的列表外观配置：无分隔线、无分组 separator。
    /// 目前是这个文件里唯一被外部使用的成员。
    func optimizedList() -> some View {
        self
            .listStyle(.plain)
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
    }
}
