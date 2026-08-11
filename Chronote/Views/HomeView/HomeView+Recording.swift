//
//  HomeView+Recording.swift
//  Lumory
//
//  HomeView 的录音 / 转写流水线。从主文件抽出来,主文件只保留 state(`recorder`
//  `@StateObject` + `recordingVM` + `transcriptionGeneration`)+ 几个 callback wire
//  到 `HomeComposerCard` 和 `.onChange(of: recorder.interruptedRecordingFileName)`。
//
//  入口:
//   - `handleMicTap()` — mic 按钮 tap,按当前状态走 start / stop
//   - `handleStopRecording()` — 用户主动停
//   - `processStoppedRecording(fileName:duration:)` — 主动停 + 音频中断共享路径,起转写
//   - `startTranscription(audioURL:fileName:)` — 转写 task 入口
//   - `retryTranscription()` — banner 重试按钮
//   - `deleteRecording(_:)` — 删除单条录音(含取消进行中的转写上传 + 删磁盘文件)
//
//  辅助(本文件 private):
//   - `deleteAudioFileFromDocuments(_:)` — 删三层音频副本(iCloud / LumoryAudio / legacy)
//   - `separatorBeforeAppendingTranscription(...)` — 转写文本拼接前的分隔决策
//

import SwiftUI
#if !os(macOS)
import AVFoundation
#endif

extension HomeView {
    /// Mic 按钮 tap:isRecording → 走 stop 路径(转写跟进);否则启录,真起录才发 start haptic。
    /// 权限未定时 startRecording 触发授权 alert 后 return false,这种"假启动"不该 haptic 暗示已开始。
    func handleMicTap() {
        if recorder.isRecording {
            Task { await handleStopRecording() }
        } else {
            // **P1 fix (2026-05-15 megareview)**:开始录音前还要 guard `!recordingVM.isTranscribing`。
            // 上一条 take 的转写还在跑(磁盘文件已删但 network task 在 fly)时,新录音的 transcription
            // 完成 callback 仍可能用旧 currentAudioFileName 比对绕开 stale-guard。开始录音前确保
            // 没有任何 transcription 在飞,避免两条 transcription path 互相干扰共享 `inputText`。
            // mic 按钮的 disabled 状态只检查 audioRecordings.count >= 1,没看 isTranscribing。
            guard !recordingVM.isTranscribing else {
                Log.info("[HomeView] mic tap ignored: prior transcription still in flight", category: .ui)
                return
            }
            let didStart = recorder.startRecording()
            if didStart {
                #if canImport(UIKit)
                HapticManager.shared.impact(.light)
                #endif
            } else {
                // (2026-05-19 superreview P1)startRecording 返 false 三种 case:
                // (1) .undetermined → 系统弹 alert 等用户选(无需 toast,alert 已是反馈);
                // (2) .denied → 用户拒过 / Settings 里关了 — UI 必须出口,否则点 mic 无反应;
                // (3) audio session config 失败 — 罕见,通用错误反馈。
                // 只对 .denied 弹 toast,带跳转 Settings action;.undetermined / 配置失败静默(系统 alert / 罕见)。
                #if canImport(UIKit) && !os(macOS)
                if AVAudioApplication.shared.recordPermission == .denied {
                    HapticManager.shared.notification(.warning)
                    LumoryToastCenter.shared.show(
                        NSLocalizedString("麦克风权限已关闭,无法录音", comment: "Mic permission denied toast"),
                        severity: .warning,
                        action: LumoryToastCenter.Action(
                            label: NSLocalizedString("设置", comment: "Open Settings"),
                            perform: {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        )
                    )
                }
                #endif
            }
        }
    }

    @MainActor
    func handleStopRecording() async {
        Log.info("[HomeView handleStopRecording START] Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
        guard let fileName = recorder.stopRecording() else {
            // (2026-05-19 P1-02 audit + superreview P2)nil = AudioRecorder 删了 < 0.5s 的文件。
            // severity=.warning 而非 .info — 用户按 stop 期待录音被保存,得到相反结果是"操作失败"
            // 反馈,要让用户体感到"出问题了"。haptic .warning 跟 severity 对齐。
            Log.info("[HomeView handleStopRecording: stopRecording returned nil — too short] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
            #if canImport(UIKit)
            HapticManager.shared.notification(.warning)
            #endif
            LumoryToastCenter.shared.show(
                NSLocalizedString("录音太短,未保存", comment: "Recording shorter than 0.5s discarded"),
                severity: .warning
            )
            return
        }
        #if canImport(UIKit)
        HapticManager.shared.impact(.light)
        #endif
        _ = processStoppedRecording(fileName: fileName, duration: recorder.duration)
    }

    @MainActor
    func finalizeActiveRecordingForBackground() {
        guard recorder.isRecording else { return }
        guard let fileName = recorder.stopRecording() else {
            Log.info("[HomeView] background recording stop returned nil", category: .ui)
            return
        }
        Log.info("[HomeView] finalized active recording before background: \(fileName)", category: .ui)
        _ = processStoppedRecording(fileName: fileName, duration: recorder.duration)
    }

    /// 走过了 `recorder.stopRecording()` 之后,把 (fileName, duration) 接进 UI 状态、清孤儿、起转写。
    /// 用户主动按停 (handleStopRecording) 和被音频中断 (recorder.interruptedRecordingFileName .onChange)
    /// 都走这里,**保证中断录到的段落不会被默默吞掉**。
    @MainActor
    @discardableResult
    func processStoppedRecording(fileName: String, duration: TimeInterval) -> Bool {
        Log.info("[HomeView processStoppedRecording: fileName=\(fileName), duration=\(duration)] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)

        // **P1 fix (2026-05-15 megareview)**:发送流程进行中(`isSending=true`)时把中断录音追加到
        // 刚被 `handleSendAction.removeAll()` 清空的 audioRecordings 列表会变孤儿(本次发送不消费它,
        // 用户看不到)。发送中直接放弃这段录音 + 删盘上文件,而非默默挂在 UI 看不见的列表里。
        // 极少触发(用户必须录完 → 立刻 send → 期间又触发 stop / interruption),但触发即数据残留。
        if inputVM.isSending {
            Log.info("[HomeView] processStoppedRecording: send in progress → discarding interrupted recording \(fileName)", category: .ui)
            deleteAudioFileFromDocuments(fileName)
            transcriptionGeneration &+= 1
            recordingVM.transcriptionTask?.cancel()
            recordingVM.transcriptionTask = nil
            recordingVM.isTranscribing = false
            if recordingVM.currentAudioFileName == fileName {
                recordingVM.currentAudioFileName = nil
            }
            recordingVM.audioRecordings.removeAll { $0.fileName == fileName }
            // (2026-05-15 superreview-4 P2)early-return 也要清前一次的转写错误。
            // 用户极端链路:转写失败 banner 还挂着 → 立刻发送一条 → 发送中途录音中断 →
            // banner 残留指向已经不存在的录音,用户疑惑"我没在转写为啥还显示错误"。
            recordingVM.transcriptionError = nil
            recordingVM.audioPlaybackError = nil
            return false
        }

        // 标记正在转录
        recordingVM.isTranscribing = true

        // UI 理论上已通过 disabled 拦住重复录音，但兜底一下：如果仍存在旧 take，
        // 删掉它们的磁盘文件，避免孤儿音频（数据模型是单值 audioFileName，不会被引用到）。
        var filesToCleanup = Set(recordingVM.audioRecordings.map(\.fileName))
        if let current = recordingVM.currentAudioFileName { filesToCleanup.insert(current) }
        filesToCleanup.remove(fileName)
        for stale in filesToCleanup {
            deleteAudioFileFromDocuments(stale)
        }

        recordingVM.currentAudioFileName = fileName
        withAnimation(AnimationConfig.stiffSpring) {
            let rec = Recording(id: fileName, fileName: fileName, duration: duration)
            recordingVM.audioRecordings.removeAll()
            recordingVM.audioRecordings.append(rec)
        }

        guard let audioURL = Self.resolvedAudioURL(fileName: fileName) else {
            recordingVM.transcriptionError = .audioReadFailed
            recordingVM.isTranscribing = false
            return false
        }

        // 进入转写任务前清掉上次的错误,新一轮开始。
        recordingVM.transcriptionError = nil
        startTranscription(audioURL: audioURL, fileName: fileName)
        Log.info("[HomeView processStoppedRecording END] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
        return true
    }

    /// 启动转写任务,失败时把错误塞进 `recordingVM.transcriptionError` 让 UI 显示 inline banner +
    /// 重试按钮。提取成方法是为了 retry 入口能复用同一段逻辑。
    private func startTranscription(audioURL: URL, fileName: String) {
        recordingVM.transcriptionTask?.cancel()
        transcriptionGeneration &+= 1
        let generation = transcriptionGeneration
        recordingVM.transcriptionTask = Task { @MainActor in
            Log.info("[HomeView startTranscription START] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
            Log.info("[HomeView] appLanguage=\(appLanguage) (OpenAITranscriber 自动检测语言,该参数当前忽略)", category: .ui)
            let transcribedTextOpt = await transcriber.transcribeAudio(fileURL: audioURL, localeIdentifier: appLanguage)
            guard generation == transcriptionGeneration, !Task.isCancelled else {
                Log.info("[HomeView transcriptionTask] stale/cancelled generation,放弃更新", category: .ui)
                return
            }
            // 文件被替换 / 删除时不更新 UI(保持原行为)。
            guard recordingVM.currentAudioFileName == fileName else {
                Log.info("[HomeView transcriptionTask] 任务文件已改变,放弃更新", category: .ui)
                recordingVM.isTranscribing = false
                return
            }
            recordingVM.isTranscribing = false
            if let transcribedText = transcribedTextOpt {
                Log.info("[HomeView transcriptionTask] 成功,长度=\(transcribedText.count)", category: .ui)
                // gpt-transcribe 会自带句末标点;只在缺失时补一个,避免双句号("test.." / "你好。。")。
                // 末尾如果是闭合引号 / 括号 / 中文版书名号(常见模式 "test." / 他说"你好。"),
                // 视作已终结 —— 句末标点惯例放在闭合符号内,外面再补 `.` 反而怪。
                let endingPunctuation: Set<Character> = [
                    ".", "。", "?", "？", "!", "！", "…",
                    "\"", "'", "”", "’", "」", "』", "》",
                    ")", "）", "】", "]", "}"
                ]
                let alreadyTerminated = transcribedText.last.map { endingPunctuation.contains($0) } ?? true
                let suffix: String = {
                    guard !alreadyTerminated else { return "" }
                    let isChinese = transcribedText.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil
                    return isChinese ? "。" : "."
                }()
                let toAppend = transcribedText + suffix
                if inputVM.inputText.isEmpty {
                    inputVM.inputText = toAppend
                } else {
                    inputVM.inputText += Self.separatorBeforeAppendingTranscription(
                        existingText: inputVM.inputText,
                        appendedText: toAppend
                    )
                    inputVM.inputText += toAppend
                }
                recordingVM.transcriptionError = nil
                #if canImport(UIKit)
                HapticManager.shared.notification(.success)
                #endif
                // 转录后不再自动分析情绪,等待发送时统一分析
            } else {
                let failure = transcriber.lastFailure ?? .networkFailed
                Log.error("[HomeView transcriptionTask] 转写失败: \(failure)", category: .ui)
                recordingVM.transcriptionError = failure
                #if canImport(UIKit)
                HapticManager.shared.notification(.warning)
                #endif
            }
        }
    }

    private static func separatorBeforeAppendingTranscription(existingText: String, appendedText: String) -> String {
        guard let last = existingText.last else { return "" }
        if last.isWhitespace || last.isNewline { return "" }

        let sentenceBoundary: Set<Character> = [
            ".", "。", "?", "？", "!", "！", "…",
            "\"", "'", "”", "’", "」", "』", "》",
            ")", "）", "】", "]", "}"
        ]
        if sentenceBoundary.contains(last) { return "\n" }

        let combined = existingText + appendedText
        let containsChinese = combined.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil
        return containsChinese ? "\n" : " "
    }

    /// inline error banner 上的"重试转写"按钮回调。
    /// 文件被删过(用户先点了删录音再点重试)就不重试,设为 .audioReadFailed。
    func retryTranscription() {
        guard let fileName = recordingVM.currentAudioFileName else { return }
        guard let audioURL = Self.resolvedAudioURL(fileName: fileName) else {
            recordingVM.transcriptionError = .audioReadFailed
            return
        }
        recordingVM.transcriptionError = nil
        recordingVM.isTranscribing = true
        startTranscription(audioURL: audioURL, fileName: fileName)
    }

    func deleteRecording(_ target: String) {
        if audioPlaybackController.currentPlayingFileName == target {
            audioPlaybackController.stopPlayback(clearCurrentFile: true)
        }
        // **隐私关键**:删除录音必须同时取消正在跑的转写上传 —— 否则用户删了录音,
        // 25 MB 的 multipart 还在飞往 OpenAI。Task.cancel 会让 URLSession 中止上传,
        // OpenAITranscriber 里 catch URLError(.cancelled) 走通用网络错误分支(无害,
        // 因为 audioRecordings 已清空,banner 不会渲染)。
        if recordingVM.currentAudioFileName == target {
            transcriptionGeneration &+= 1
            recordingVM.transcriptionTask?.cancel()
            recordingVM.transcriptionTask = nil
            recordingVM.isTranscribing = false
        }
        deleteAudioFileFromDocuments(target)
        // 删除录音时使用动画
        withAnimation(AnimationConfig.stiffSpring) {
            recordingVM.audioRecordings.removeAll { $0.fileName == target }
        }
        // 清掉对已删除文件的悬空引用，否则再发送会把不存在的文件名落库
        if recordingVM.currentAudioFileName == target {
            recordingVM.currentAudioFileName = nil
        }
        // 录音被删了,挂着的转写 / 播放错误 banner 也没意义了。
        recordingVM.transcriptionError = nil
        recordingVM.audioPlaybackError = nil
        recordingVM.deleteTarget = nil
    }

    private func deleteAudioFileFromDocuments(_ fileName: String) {
        do {
            try LumoryAttachmentPaths.deleteAllCopies(fileName: fileName, kind: .audio)
        } catch {
            Log.error("[HomeView] 删除音频文件出错 (\(fileName)): \(error.localizedDescription)", category: .ui)
        }
    }
}
