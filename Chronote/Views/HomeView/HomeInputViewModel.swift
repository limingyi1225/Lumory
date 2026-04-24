import SwiftUI
import Foundation

// MARK: - Send Button State Machine
//
// 从 HomeView.swift 顶层 moved 到这里 —— 只在输入/发送这一路被引用（HomeView 的
// `keyboardActionsBar` / `handleSendAction` / `hasSendableContent`）。enum 本身没有
// 状态，只是发送按钮动画的 phase 标记，放在 InputVM 这边内聚性最高。
enum SendButtonState {
    case idle           // 蓝色（默认状态）
    case sending        // 灰色loading（AI分析中）
    case moodRevealing  // 情绪颜色+脉冲动画（1.2秒）
    case completed      // 淡出回到蓝色
}

/// HomeView 的"输入 / 情绪 / 发送动画"相关状态合成一层 VM。
///
/// 原 `HomeView` 的 20+ 个 `@State` 里,只要和**文本输入、心情、发送按钮动画、提示占位语**
/// 有关的,全部收束到这里。路由(`selectedEntry` / `isSettingsOpen` 等)、搜索
/// (`searchQuery` / `searchResults`)、数据库回调(`databaseRecreationObserver`)仍留在
/// HomeView 自己,因为它们和 View 生命周期更耦合。
///
/// 迁移原则: 字段初值、顺序、可见性 1:1 搬过来,不重命名。所有 SwiftUI 动画 / `onChange`
/// / `Task` 的驱动代码原位留在 `HomeView` 里,只是读写目标从 `self.xxx` 变成 `inputVM.xxx`。
///
/// **线程安全**: iOS 26 的 `@Observable` 宏在 SwiftUI `@State`-owned 场景下默认主线程访问。
/// 当前所有写点都已经在 `MainActor` 上(对应 HomeView 里的 `MainActor.run`),迁移后不变。
@available(iOS 17.0, *)
@Observable
final class HomeInputViewModel {
    // MARK: 文本 / 情绪
    var inputText: String = ""
    var moodValue: Double = 0.5

    // MARK: 发送流程
    var isSending: Bool = false
    var sendButtonState: SendButtonState = .idle

    /// AI 回来的最终 mood,发送完成动画展开 2s 期间用
    var revealedMood: Double? = nil
    /// 历史遗留标记,保留给未来 UI(搜了一圈当前没有读点,但和原 `@State` 一起搬过来保证平移)。
    var showMoodReveal: Bool = false
    /// 光谱条的显示状态:idle / analyzing / revealed。原先在 HomeView 里。
    var spectrumDisplayState: SpectrumDisplayState = .idle

    // MARK: 占位语 / 起手语
    /// 稳定的占位语——只在明确时刻更新（进入页面 / 发送完成 / AI 池刷新完成），
    /// 避免 body 重评时反复换给人"抽风"的感觉。
    var stablePlaceholder: String = ""
    var contextPrompts: [ContextPrompt] = []
}
