//
//  HomeView+Audio.swift
//  Lumory
//
//  HomeView 的音频播放路径(playAudio + 文件解析 + 键盘隐藏 helper)。
//  入口:`playAudio(fileName:)` —— composer 行内播放按钮回调。
//
//  辅助:
//   - `resolvedAudioURL(fileName:)` 三层 fallback 统一走 `LumoryAttachmentPaths`。
//     `retryTranscription`(HomeView+Recording.swift)也用,跨 extension 需 internal。
//   - `hideKeyboard()` —— UIKit `resignFirstResponder` 兜底。`handleSendAction`(HomeView+Send.swift)也调。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension HomeView {

    static func resolvedAudioURL(fileName: String) -> URL? {
        LumoryAttachmentPaths.existingAudioURL(fileName: fileName)
    }

    func playAudio(fileName: String) {
        Log.info("[HomeView playAudio START] Requested to play: \(fileName). Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)

        guard let audioURL = Self.resolvedAudioURL(fileName: fileName) else {
            Log.info("[HomeView playAudio] File NOT FOUND: \(fileName). Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
            LumoryToastCenter.shared.show(
                NSLocalizedString("无法播放该录音,文件可能已损坏或丢失。",
                                  comment: "Audio playback failure banner"),
                severity: .warning
            )
            Log.info("[HomeView playAudio] Removing stale missing recording row: \(fileName)", category: .ui)
            let wasCurrentRecording = recordingVM.currentAudioFileName == fileName
            withAnimation(AnimationConfig.standardResponse) {
                if wasCurrentRecording {
                    recordingVM.currentAudioFileName = nil
                }
                recordingVM.audioRecordings.removeAll { $0.fileName == fileName }
            }
            if wasCurrentRecording {
                recordingVM.transcriptionTask?.cancel()
                recordingVM.transcriptionTask = nil
                recordingVM.isTranscribing = false
            }
            if audioPlaybackController.currentPlayingFileName == fileName {
                audioPlaybackController.stopPlayback()
            }
            return
        }
        // 新一次 play 成功就清掉旧错误 banner;onPlayError / missing-file path 会再 set。
        recordingVM.audioPlaybackError = nil

        Log.info("[HomeView playAudio] File exists for: \(fileName). Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)

        if audioPlaybackController.isPlaying && audioPlaybackController.currentPlayingFileName != fileName {
            Log.info("[HomeView playAudio] Controller was playing another file (\(audioPlaybackController.currentPlayingFileName ?? "nil")). Stopping it. Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
            audioPlaybackController.stopPlayback(clearCurrentFile: true)
            Log.info("[HomeView playAudio] Controller stopped. Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
        }

        // **关键顺序**:callback 必须在 `play()` **之前**注册。AVAudioPlayer init 偶尔会同步抛
        // (corrupt file / unsupported codec),controller.play 内 catch 后**同步** call onPlayError。
        // 之前的顺序是 play → 设回调,这种同步错误就丢了 banner 不会显示。
        //
        // **引用循环防护**:闭包存在 audioPlaybackController 身上、访问 recordingVM.currentAudioFileName,
        // recordingVM 是 `@Observable` 引用类型,若闭包强捕获 recordingVM:
        // closure → recordingVM → (nothing back) —— VM 不持 controller,不成环。
        // 但 HomeView 的 @StateObject 存储仍是引用语义,self-capture 仍有风险。
        // 做法:抓 [weak audioPlaybackController, weak recordingVM];不在闭包里提到 self。
        audioPlaybackController.onFinishPlaying = { [weak audioPlaybackController, weak recordingVM, capturedFileName = fileName] in
            Task { @MainActor in
                guard let controller = audioPlaybackController else { return }
                Log.info("[HomeView playAudio CB_Finish] Playback finished for \(capturedFileName)", category: .ui)
                if recordingVM?.currentAudioFileName == nil && capturedFileName == controller.currentPlayingFileName {
                    withAnimation(AnimationConfig.standardResponse) {
                        recordingVM?.currentAudioFileName = capturedFileName
                    }
                }
                if !controller.isPlaying, controller.currentPlayingFileName == capturedFileName {
                    controller.stopPlayback(clearCurrentFile: true)
                }
            }
        }
        audioPlaybackController.onPlayError = { [weak audioPlaybackController, weak recordingVM, capturedFileName = fileName] error in
            Task { @MainActor in
                guard let controller = audioPlaybackController else { return }
                Log.error("[HomeView playAudio CB_Error] Playback error for \(capturedFileName): \(error.localizedDescription)", category: .ui)
                // **失败提示**:之前只 log,用户感知不到。塞进 VM 让 banner 显示。
                recordingVM?.audioPlaybackError = NSLocalizedString("无法播放该录音,文件可能已损坏或丢失。",
                                                                    comment: "Audio playback failure banner")
                if recordingVM?.currentAudioFileName == nil && capturedFileName == controller.currentPlayingFileName {
                    withAnimation(AnimationConfig.standardResponse) {
                        recordingVM?.currentAudioFileName = capturedFileName
                    }
                }
                if controller.currentPlayingFileName == capturedFileName {
                    controller.stopPlayback(clearCurrentFile: true)
                }
            }
        }

        // **真正调 play 在回调装好之后**,见上方注释。同步抛错时 onPlayError 已经能接到。
        Log.info("[HomeView playAudio] Calling controller.play for: \(fileName). Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
        audioPlaybackController.play(url: audioURL, fileName: fileName)
        Log.info("[HomeView playAudio] Called controller.play. Controller isPlaying: \(audioPlaybackController.isPlaying), Controller file: \(audioPlaybackController.currentPlayingFileName ?? "nil"). Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)

        if recordingVM.currentAudioFileName != fileName {
            Log.info("[HomeView playAudio] SFCFN (\(recordingVM.currentAudioFileName ?? "nil")) != fileName (\(fileName)). Restoring SFCFN.", category: .ui)
            withAnimation(AnimationConfig.standardResponse) {
                 recordingVM.currentAudioFileName = fileName // SET FILENAME
                 Log.info("[HomeView playAudio] Did set SFCFN to \(fileName). New SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
            }
        }
        Log.info("[HomeView playAudio END] For: \(fileName). SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
    }

    func hideKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}
