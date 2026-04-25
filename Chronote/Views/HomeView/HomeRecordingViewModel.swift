import SwiftUI
import Foundation

/// HomeView 的"录音 / 转写"相关状态合成一层 VM。
///
/// 设计决策:**`AudioRecorder` 和 `AudioPlaybackController` 继续留在 HomeView 里作为
/// `@StateObject`**,**不**搬进这层 VM。原因:
///
/// 1. 二者都是 `ObservableObject`(`@Published` 语义),SwiftUI 订阅它们的
///    `objectWillChange` 依赖 `@StateObject` 的 property-wrapper 安装。
/// 2. `@Observable` 宏只跟踪 VM 自身 stored properties 的读取;把一个 ObservableObject 当
///    `let` 存进来,SwiftUI 收不到内部 `@Published` 的变化——`recorder.isRecording` /
///    `controller.isPlaying` 的改动不会再触发 body 重评,symbol 动画、录音计时、播放进度
///    条全哑。
/// 3. 原 HomeView 到处用 `recorder.isRecording` / `recorder.duration` / `audioPlaybackController.xxx`
///    直接读取驱动 UI,改到 VM 就要新增大量 `@ObservedObject` 转接,违反"不要改变任何业务
///    行为"的底线。
///
/// 所以这一层只收录以 `@State`(值类型)承载的录音/转写派生状态。两个 controller 仍在
/// `HomeView` 的 `@StateObject`,通过方法 / 参数传给 VM 使用。
///
/// 迁移原则: 字段初值、顺序、可见性 1:1 搬过来,不重命名。
@available(iOS 17.0, *)
@Observable
final class HomeRecordingViewModel {
    /// 正在转写中。按钮 disabled、动画切换靠这个。
    var isTranscribing: Bool = false

    /// 当前这次输入对应的音频文件名(单值,和 DiaryEntry.audioFileName 模型对齐)。
    /// 录制完成后写入,发送或删除后清空。
    var currentAudioFileName: String?

    /// 进行中的转写任务,允许 cancel。
    var transcriptionTask: Task<Void, Never>?

    /// UI 层 recording cell 列表。数据模型只持久化一段(DiaryEntry.audioFileName 是单值),
    /// UI 最多保留 1 条 take;重录前用户需要先删除已有 take。
    var audioRecordings: [Recording] = []

    // MARK: 删除录音确认弹窗
    var showingDeleteAlert: Bool = false
    var deleteTarget: String?
}
