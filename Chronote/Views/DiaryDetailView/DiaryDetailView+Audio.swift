//
//  DiaryDetailView+Audio.swift
//  Lumory
//
//  DiaryDetailView 的音频时长 fetch + 播放 / 暂停。从主文件抽出来。
//  入口:
//   - `fetchAudioDuration(url:)` — `audioBlock.task` 调,异步读 AVURLAsset duration
//   - `playOrPauseAudio(url:fileName:)` — audioBlock play 按钮回调
//

import SwiftUI
import AVFoundation

extension DiaryDetailView {

    func refreshResolvedAudioURL() async {
        guard let fileName = entry.audioFileName else {
            resolvedAudioURL = nil
            displayableAudioDuration = 0
            return
        }
        let url = await Task.detached(priority: .utility) {
            DiaryEntry.resolvedAudioURL(fileName: fileName)
        }.value
        guard entry.audioFileName == fileName else { return }
        resolvedAudioURL = url
        if url == nil {
            displayableAudioDuration = 0
        }
    }

    // 辅助函数：获取音频文件时长 - marked async
    func fetchAudioDuration(url: URL) async -> TimeInterval? {
        let audioAsset = AVURLAsset(url: url)
        // try? handles potential error by returning nil, no do-catch needed here
        return try? await audioAsset.load(.duration).seconds
    }

    func playOrPauseAudio(url: URL, fileName: String) {
        // **关键顺序**:callback 必须在 `play()` **之前**注册。AVAudioPlayer init 偶尔会同步抛
        // (corrupt file / unsupported codec),controller.play 内 catch 后**同步** call onPlayError。
        // 之前的顺序是 play → 设回调,这种同步错误就丢了用户提示。HomeView+Audio.swift 已是这个顺序。
        audioPlaybackController.onFinishPlaying = { [weak audioPlaybackController] in
            Log.info("[DiaryDetailView] Playback finished. Controller isPlaying: \(audioPlaybackController?.isPlaying ?? false)", category: .ui)
        }
        audioPlaybackController.onPlayError = { [weak audioPlaybackController] error in
            let fileName = audioPlaybackController?.currentPlayingFileName ?? "N/A"
            Log.error("[DiaryDetailView] Audio playback error: \(error.localizedDescription). Controller file: \(fileName)", category: .ui)
            // 向用户显示反馈 — 不再静默。走全局 LumoryToastCenter,DiaryDetailView root
            // 已挂 `.lumoryToastOverlay()`(views-design-tokens rule "Toast 入口")。
            // `.warning` 已经走红色 + 警示三角图标(LumoryToast.swift Severity 没有 `.error` case,
            // `.warning` 就是 destructive 视觉档),语义足够覆盖播放失败。
            LumoryToastCenter.shared.show(
                NSLocalizedString("音频播放失败", comment: "DiaryDetailView audio playback error toast"),
                severity: .warning
            )
        }
        audioPlaybackController.play(url: url, fileName: fileName)
    }
}
