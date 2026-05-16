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

    // 辅助函数：获取音频文件时长 - marked async
    func fetchAudioDuration(url: URL) async -> TimeInterval? {
        let audioAsset = AVURLAsset(url: url)
        // try? handles potential error by returning nil, no do-catch needed here
        return try? await audioAsset.load(.duration).seconds
    }

    func playOrPauseAudio(url: URL, fileName: String) {
        audioPlaybackController.play(url: url, fileName: fileName)

        // Removed problematic and unused knownDuration block.
        // Duration loading is handled by .task and AudioPlaybackController internally.

        // 设置播放结束和错误的回调
        audioPlaybackController.onFinishPlaying = { [weak audioPlaybackController] in
            // UI 可以在这里更新，例如重置播放按钮状态
            Log.info("[DiaryDetailView] Playback finished. Controller isPlaying: \(audioPlaybackController?.isPlaying ?? false)", category: .ui)
        }
        audioPlaybackController.onPlayError = { [weak audioPlaybackController] error in // Added weak capture for consistency if needed
            let fileName = audioPlaybackController?.currentPlayingFileName ?? "N/A"
            Log.error("[DiaryDetailView] Audio playback error: \(error.localizedDescription). Controller file: \(fileName)", category: .ui)
            // 可以在这里向用户显示错误信息
        }
    }
}
