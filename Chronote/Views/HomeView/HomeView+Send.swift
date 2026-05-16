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

extension HomeView {

    /// handleSendAction 内部抓取 `inputVM` / `recordingVM` / `photoVM` 三个 VM 的当前值,失败回滚时复原。
    /// `private` 因为只在本 extension 文件内消费,跨 extension 无意义。
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
                Log.info("[HomeView SendButton] Mood revealed: \(finalMoodValue)", category: .ui)
            }

            // 4. 把落库和 2 秒光谱动画并行跑 —— 保存不再被动画白白拖 2 秒,
            //    动画也不会被慢网络/磁盘 I/O 拖过 2 秒。
            // **service 边界**:`EntryCreationService.create` 一手包办附件 I/O + Core Data save +
            // Reminder reschedule + StreakMilestone + fire-and-forget AI writeback(stale-guard 在
            // service 内部)。HomeView 只 await Result.didSave 控 UI 状态机。
            let saveTask = Task {
                return await EntryCreationService.create(
                    .init(
                        text: textToSend,
                        audioFileName: audioToSend,
                        images: imagesToSend,
                        moodValue: finalMoodValue
                    ),
                    in: PersistenceController.shared,
                    viewContext: viewContext,
                    ai: aiService
                ).didSave
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // 起手语刷新是给"下一条"用的，完全不必卡住当前发送的收尾动画。
            Task { await loadContextPrompts() }

            // 等落库真正完成再亮"完成"状态，避免按钮骗人。
            let didSave = await saveTask.value
            guard didSave else {
                await MainActor.run {
                    withAnimation(AnimationConfig.smoothTransition) {
                        inputVM.inputText = textToSend
                        inputVM.sendButtonState = .idle
                        inputVM.isSending = false
                        inputVM.revealedMood = nil
                        inputVM.spectrumDisplayState = .idle
                        recordingVM.currentAudioFileName = audioToSend
                        recordingVM.audioRecordings = audioToSend.map {
                            [Recording(id: $0, fileName: $0, duration: audioDurationToRestore)]
                        } ?? []
                        photoVM.selectedImageItems = imagesToSend.map { HomePhotoViewModel.SelectedImage(data: $0) }
                        photoVM.selectedPhotos = photosToSend
                    }
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
                LumoryToastCenter.shared.show(
                    NSLocalizedString("已记录", comment: "Toast after diary entry saved"),
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
            }

            Log.info("[HomeView SendButton] Send action completed", category: .ui)
        }
    }
}
