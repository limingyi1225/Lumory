//
//  HomeView+Send.swift
//  Lumory
//
//  HomeView 的发送日记流水线。从主文件抽出来。`handleSendAction()` 是 `HomeComposerCard`
//  发送按钮的 `onSend` 回调,把"snapshot 输入 → 清 UI → AI 情绪分析 → 落库 → 完成动画"
//  的 7 步串成一个 Task。失败回滚 + 重发双点 guard 都在这里。
//
//  **service 边界**:真正的"附件 I/O + Core Data save + Reminder reschedule + StreakMilestone +
//  fire-and-forget AI writeback"早在 wave12 抽到 `EntryCreationService`,这里只 await
//  `Result.didSave` 控 UI 状态机。
//

import SwiftUI
import PhotosUI
import Foundation

extension HomeView {

    /// handleSendAction 内部抓取 `inputVM` / `recordingVM` / `photoVM` 三个 VM 的当前值,失败回滚时复原。
    /// `internal` 因 extension scope 默认无 private 修饰;只在本文件消费,无外部 caller
    /// (grep `SendSnapshot` 全仓 4 处全在 +Send.swift)。
    struct SendSnapshot {
        let text: String
        let audio: String?
        // 失败回滚时,Recording 要带回真实时长,不然 audio row 会显示 0:00
        // 即便文件还在。原始 Recording.duration 来自 recorder.duration,这里同步快照下来。
        let audioDuration: TimeInterval
        let images: [Data]
        let photos: [PhotosPickerItem]
        let mood: Double
    }

    @MainActor
    func handleSendAction() {
        // 重发双点防护：`hasSendableContent` 已包含 `!isSending`，但用户触到第二次 tap 的极端
        // race（SwiftUI tap dispatch + `isSending` 还没 flip）在 struct-copy 语义下仍可能穿透。
        // 这里再加一层 synchronous guard 作为底线：同一个 HomeView 实例里永远最多一个发送在跑。
        guard !inputVM.isSending else {
            Log.info("[HomeView SendButton] 已有发送在跑，忽略重复 tap", category: .ui)
            return
        }
        // **必须**同步置位。以前 `isSending = true` 写在下面 `Task { MainActor.run { ... } }`
        // 里，两次极速 tap 之间的 SwiftUI dispatch 窗口（第一次 Task 尚未跑进 MainActor.run）
        // 内，第二次 tap 照样能过上面的 guard —— 两条日记双发落库。
        // handleSendAction 由 Button action 触发，天然在主线程，VM 字段同步写合法。
        inputVM.isSending = true
        // 发送触觉分两段:按钮点按只给 .soft 的轻反馈,保存完成再给 .success。
        // mood reveal 不额外 haptic,避免一条发送链路抖成三连击。
        Task {
            // 1. 发送开始：snapshot 输入 + 立即清空 UI，避免 2 秒动画窗口内继续打字造成
            //    情绪分析文本与落库文本错位，或新输入被后续清空吞掉。
            //    (A-04 superreview 2026-05-19) 同时 cancel 在飞的转写 task —— 否则转写完成时
            //    `inputText += toAppend` 的 path 虽被 `currentAudioFileName` 清空的 guard 拦住,
            //    转写文本仍被静默丢弃,用户以为录音转写跟着语音一起进了刚发的日记。捕获
            //    `wasTranscribingAtSend` 让收尾段 toast 告诉用户"转写没拼上"。
            let wasTranscribingAtSend = await MainActor.run { recordingVM.isTranscribing }
            let snapshot = await MainActor.run { () -> SendSnapshot in
                let captured = SendSnapshot(
                    text: inputVM.inputText,
                    audio: recordingVM.currentAudioFileName,
                    audioDuration: recordingVM.audioRecordings.first?.duration ?? 0,
                    images: photoVM.selectedImages,
                    photos: photoVM.selectedPhotos,
                    mood: inputVM.moodValue
                )

                Log.info("[HomeView SendButton] Starting send action", category: .ui)
                // A-04 fix: cancel in-flight transcription before clearing UI 状态.
                recordingVM.transcriptionTask?.cancel()
                recordingVM.transcriptionTask = nil
                recordingVM.isTranscribing = false
                withAnimation(AnimationConfig.standardResponse) {
                    inputVM.sendButtonState = .sending
                    // isSending 已在 Task 外同步置 true，这里不重复写。
                    inputVM.spectrumDisplayState = .analyzing  // 光谱进入分析状态（呼吸效果）
                }
                withAnimation(AnimationConfig.fastResponse) {
                    inputVM.inputText = ""
                    recordingVM.currentAudioFileName = nil
                    recordingVM.audioRecordings.removeAll()
                    photoVM.selectedImageItems.removeAll()
                    photoVM.selectedPhotos.removeAll()
                }
                hideKeyboard()
                // 发送完成：换一条占位语给用户新的灵感
                rollPlaceholderIfNeeded(force: true)

                return captured
            }

            let textToSend = snapshot.text
            let audioToSend = snapshot.audio
            let audioDurationToRestore = snapshot.audioDuration
            let imagesToSend = snapshot.images
            let photosToSend = snapshot.photos
            var finalMoodValue = snapshot.mood

            // 2. 执行AI情绪分析（基于 snapshot 的文本，只调用一次）
            let textToAnalyze = textToSend.trimmingCharacters(in: .whitespacesAndNewlines)

            if !textToAnalyze.isEmpty {
                Log.info("[HomeView SendButton] Analyzing mood for text", category: .ui)
                let mood = await aiService.analyzeMood(text: textToAnalyze)
                finalMoodValue = mood
                await MainActor.run {
                    inputVM.moodValue = mood
                }
            }

            // 3. 显示情绪反馈 → spectrum揭示结果（光点聚焦动画）
            await MainActor.run {
                withAnimation(AnimationConfig.smoothTransition) {
                    inputVM.revealedMood = finalMoodValue
                    inputVM.sendButtonState = .moodRevealing
                    inputVM.spectrumDisplayState = .revealed  // 光谱显示结果
                }
                // mood reveal 窗口的交互信号必须在 watchdog 起跑前重置。否则上一轮发送
                // 遗留的 commitRequested = true 会让本轮 watchdog 立刻退出 = 用户没机会改。
                inputVM.moodEditTouchTick = 0
                inputVM.moodEditReleasedAt = nil
                Log.info("[HomeView SendButton] Mood revealed: \(finalMoodValue)", category: .ui)
            }

            // 4. 立刻启动落库,把正文/附件先持久化。mood reveal 窗口只负责后续微调 mood,
            // 不再让刚写的日记在 2.5-12s 内只存在 `textToSend` 这个内存 snapshot 里。
            let initialMoodForSave = finalMoodValue
            let saveTask = Task { @MainActor in
                await EntryCreationService.create(
                    .init(
                        text: textToSend,
                        audioFileName: audioToSend,
                        images: imagesToSend,
                        moodValue: initialMoodForSave
                    ),
                    in: PersistenceController.shared,
                    viewContext: viewContext,
                    ai: aiService
                )
            }

            // 5. 给 mood reveal 一个交互驱动的可编辑窗口。老实现 `sleep(2s)` 一刀切,
            // 用户根本来不及拖。新实现见下方 helper:没碰过 2.5s 收尾 / 拖动中不收尾 /
            // 松手即收尾(~100ms poll 延迟)/ 12s 硬上限兜底。
            // (A-07 superreview 2026-05-19) 此处 + helper docstring + helper inline 注释三处
            // 时长描述必须一致,不要再回到"4s / 1.5s"旧值,跟实际常量 2.5 / 0.0 对不上。
            await Self.waitForMoodEditWindowToClose(inputVM: inputVM)
            finalMoodValue = await MainActor.run {
                inputVM.revealedMood ?? finalMoodValue
            }

            // **service 边界**:`EntryCreationService.create` 一手包办附件 I/O + Core Data save +
            // Reminder reschedule + StreakMilestone + fire-and-forget AI writeback(stale-guard 在
            // service 内部)。HomeView 拿 Result 以便失败 toast 能说明原因。
            let saveResult = await saveTask.value
            if case .saved(let entryID) = saveResult, finalMoodValue != initialMoodForSave {
                let didUpdateMood = await MainActor.run {
                    EntryCreationService.updateMood(
                        entryID: entryID,
                        moodValue: finalMoodValue,
                        viewContext: viewContext
                    )
                }
                if !didUpdateMood {
                    await MainActor.run {
                        #if canImport(UIKit)
                        HapticManager.shared.notification(.warning)
                        #endif
                        LumoryToastCenter.shared.show(
                            NSLocalizedString("已记录,但心情调整保存失败。", comment: "Mood update after save failed"),
                            severity: .warning
                        )
                    }
                }
            }

            // 起手语刷新是给"下一条"用的，完全不必卡住当前发送的收尾动画。
            Task { await loadContextPrompts() }

            // 等落库真正完成再亮"完成"状态，避免按钮骗人。
            guard saveResult.didSave else {
                await MainActor.run {
                    // (A-08 superreview 2026-05-19) 用户在 mood reveal 2.5s 窗口期 + watchdog
                    // poll 期间 TextField 仍可输入,直接 `inputText = textToSend` 会盖掉用户
                    // 新打的字。改成 prepend:把发送时的 snapshot 文本放回最前,新输入留在
                    // 末尾,空行分隔。
                    let pendingDuringWindow = inputVM.inputText
                    let restored: String = pendingDuringWindow.isEmpty || pendingDuringWindow == textToSend
                        ? textToSend
                        : "\(textToSend)\n\n\(pendingDuringWindow)"
                    withAnimation(AnimationConfig.smoothTransition) {
                        inputVM.inputText = restored
                        inputVM.sendButtonState = .idle
                        inputVM.isSending = false
                        inputVM.revealedMood = nil
                        inputVM.spectrumDisplayState = .idle
                        // 失败回滚也要清掉 watchdog 信号 —— 下一次发送 .moodRevealing
                        // 之前已经重置一次,但这里再清一次保证回滚态干净。
                        inputVM.moodEditTouchTick = 0
                        inputVM.moodEditReleasedAt = nil
                        let restorableAudio = audioToSend.flatMap { fileName in
                            LumoryAttachmentPaths.existingAudioURL(fileName: fileName) == nil ? nil : fileName
                        }
                        recordingVM.currentAudioFileName = restorableAudio
                        recordingVM.audioRecordings = restorableAudio.map {
                            [Recording(id: $0, fileName: $0, duration: audioDurationToRestore)]
                        } ?? []
                        photoVM.selectedImageItems = imagesToSend.map { HomePhotoViewModel.SelectedImage(data: $0) }
                        photoVM.selectedPhotos = photosToSend
                    }
                    // (megareview P1 #5)发送失败彻底静默 → user 只看到内容神秘出现,不知何故。
                    // 加 error haptic + warning toast(Toast.Severity 只有 success/info/warning),
                    // 跟同 view 转写失败 inline banner / DiaryDetailView 保存失败 alert 对齐反馈强度。
                    #if canImport(UIKit)
                    HapticManager.shared.notification(.error)
                    #endif
                    if let failureError = saveResult.failureError {
                        Log.error("[HomeView SendButton] save failed: \(failureError)", category: .ui)
                    }
                    LumoryToastCenter.shared.show(
                        Self.sendFailureMessage(error: saveResult.failureError),
                        severity: .warning
                    )
                }
                return
            }

            // 7. 完成动画 → 重置状态
            await MainActor.run {
                withAnimation(AnimationConfig.smoothTransition) {
                    inputVM.sendButtonState = .completed
                    inputVM.isSending = false
                }
                // P0-2 send 完成成功反馈 — 之前完全没 haptic,跟"删 / 存"高频动作统一。
                #if canImport(UIKit)
                HapticManager.shared.notification(.success)
                #endif
                // (A-04 superreview 2026-05-19) 如果发送时转写还在飞,我们刚 cancel 掉了它,
                // 录音文件本身存进去了但对应文字没拼上。toast 文案 +1 行让用户知道这件事,
                // 否则就是 silent data loss(用户以为转写跟着语音一起进了日记)。
                let toastKey = wasTranscribingAtSend
                    ? "已记录 · 录音转写未完成"
                    : "已记录"
                LumoryToastCenter.shared.show(
                    NSLocalizedString(toastKey, comment: "Toast after diary entry saved"),
                    severity: .success
                )
            }

            try? await Task.sleep(nanoseconds: 300_000_000)

            await MainActor.run {
                withAnimation(AnimationConfig.smoothTransition) {
                    inputVM.sendButtonState = .idle
                    inputVM.revealedMood = nil
                    inputVM.spectrumDisplayState = .idle  // 光谱重置
                }
                inputVM.moodEditTouchTick = 0
                inputVM.moodEditReleasedAt = nil
            }

            Log.info("[HomeView SendButton] Send action completed", category: .ui)
        }
    }

    /// AI 揭晓后,等用户的可编辑窗口收尾再返回。规则:
    /// - 用户从未碰过光谱条:`initialWindow`(2.5s)后返回
    /// - 用户在拖:不返回(由 `hardCap` 兜底,见下)
    /// - 用户松手:`idleAfterRelease`(0s,实际 ≈ 一次 poll = 100ms)即返回 —— 松手即落库,
    ///   跟拖动条 / scrubber 语义一致。想反悔就手指再按上去,`onChanged` 重置 `releasedAt`,
    ///   自动回到"按住"分支。
    /// - 任何情况下 `hardCap`(12s)硬上限 —— 防止用户压住光谱不放或者 watchdog 卡住
    ///
    /// 实现走 100ms poll。`@Observable` 在非 SwiftUI body 的读访问不会订阅,只是取
    /// 最新值,所以 poll 是显式且廉价的;让 watchdog 状态机一眼看懂比塞 continuation
    /// 更容易维护。
    ///
    /// **A-01 / G-01 superreview 2026-05-19** — `while true` 而非 `while !Task.isCancelled`:
    /// `handleSendAction` 起的 send Task 是 fire-and-forget,view 没存 handle,**没人能 cancel 它**;
    /// `Task.isCancelled` 永远 false,曾经的 `!Task.isCancelled` guard 是 dead code 且会误导维护者
    /// 以为"view 离场会安全退出"。明确改 `while true` 对齐"绝不取消"的现实,退出靠
    /// hardCap / idle 收尾。若未来需要真支持 view-disappear cancel,在 inputVM / HomeView 加
    /// `sendTask: Task<Void, Never>?` ivar + `onDisappear { sendTask?.cancel() }` 一同改。
    @MainActor
    private static func waitForMoodEditWindowToClose(inputVM: HomeInputViewModel) async {
        let started = Date()
        let initialWindow: TimeInterval = 2.5
        let idleAfterRelease: TimeInterval = 0.0
        let hardCap: TimeInterval = 12.0
        let pollInterval: UInt64 = 100_000_000  // 100ms

        while true {
            let now = Date()
            let elapsed = now.timeIntervalSince(started)
            if elapsed >= hardCap { break }

            if inputVM.moodEditTouchTick == 0 {
                // 用户从未交互:走初始 2.5s 窗口(A-07 fix: 此前 inline 注释 stale 写"4s")
                if elapsed >= initialWindow { break }
            } else if let releasedAt = inputVM.moodEditReleasedAt {
                // 用户最近一次松手了:从松手时刻起算 idle(实际 0s + 一次 poll ≈ 100ms)
                if now.timeIntervalSince(releasedAt) >= idleAfterRelease { break }
            }
            // 否则 (touchTick > 0 且 releasedAt == nil):用户正在按住光谱,继续 poll

            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private static func sendFailureMessage(error: Error?) -> String {
        guard let error else {
            return NSLocalizedString("发送失败,内容已恢复。请稍后再试。", comment: "Generic send failure toast")
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteOutOfSpaceError:
                return NSLocalizedString("发送失败: 存储空间不足。内容已恢复。", comment: "Send failure: disk full")
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return NSLocalizedString("发送失败: 无法写入本地数据。内容已恢复。", comment: "Send failure: no permission")
            default:
                break
            }
        }

        return NSLocalizedString("发送失败,内容已恢复。请稍后再试。", comment: "Generic send failure toast")
    }
}
