import SwiftUI
import WidgetKit

struct QuickWriteWidget: Widget {
    var body: some WidgetConfiguration {
        // **kind 必须用 LumoryWidgetKind.quickWrite**(从 LumoryWidgetShared 引)
        // —— 主 App `WidgetCenter.reloadTimelines(ofKind:)` 也用同一常量。
        // 写错就 silent no-op:reload 找不到 widget,系统不报错。
        StaticConfiguration(kind: LumoryWidgetKind.quickWrite, provider: QuickWriteProvider()) { entry in
            QuickWriteEntryView(entry: entry)
        }
        .configurationDisplayName(LocalizedStringResource("widget.display_name"))
        .description(LocalizedStringResource("widget.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
