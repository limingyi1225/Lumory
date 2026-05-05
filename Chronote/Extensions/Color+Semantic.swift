import SwiftUI

// MARK: - 语义色 token
//
// 历史上 Settings / AdvancedSettings 多处直接写 `.red` / `.orange` / `.accentColor` /
// `.moodSpectrum(value: 0.85)` 表达"破坏性 / 警告 / 操作 / 成功"。意思相同但 callsite 看一眼
// 不知道是不是同一个语义,改 brand color 时改不全。这里给四个固定 token,新代码统一用语义而不是
// 直觉色。
//
// 现有 callsite 沿用 `.red` / `.orange` 不强制替换 — 用 grep 替换风险大于收益,本轮只把 Settings
// 高频踩坑路径(数据库修复 / 删除全部 / 同步异常)迁过来。
extension Color {
    /// 不可逆破坏:删除全部 / 重置数据库
    static let semanticDestructive: Color = .red

    /// 警告 / 半态:同步异常 / 数据库修复 / 即将不可逆
    static let semanticWarning: Color = .orange

    /// 操作型 affordance:导入 / 导出 / 主功能 row
    static let semanticAction: Color = .accentColor

    /// 成功 / 已完成:同步 OK / 索引已就绪
    /// 复用 moodSpectrum 的 high-positive 端,跟 Insights 暖绿同源
    static var semanticSuccess: Color { Color.moodSpectrum(value: 0.85) }
}
