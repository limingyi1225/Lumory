import AVFoundation
import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// 全局辅助函数：格式化时长
func formattedDuration(currentTime: TimeInterval, totalDuration: TimeInterval) -> String {
    let currentIntSec = Int(max(0, currentTime))
    let current_m = currentIntSec / 60
    let current_s = currentIntSec % 60

    if totalDuration > 0 {
        let totalIntSec = Int(max(0, totalDuration))
        let total_m = totalIntSec / 60
        let total_s = totalIntSec % 60
        return String(format: "%02d:%02d / %02d:%02d", current_m, current_s, total_m, total_s)
    } else {
        return String(format: "%02d:%02d", current_m, current_s)
    }
}

#if canImport(UIKit)
/// CADisplayLink 要求 `target` 保持 Obj-C runtime 可访问，它会**强引用** target。
/// 让它直接指向 AudioPlaybackController 会造成 `displayLink ⇄ controller` 循环强引用
/// （controller 存 displayLink，displayLink 存 controller），导致 deinit 不触发、音频会话泄漏。
/// 这里放一个弱回指的代理，由代理中转调用，controller 可以被正常释放。
private final class DisplayLinkProxy: NSObject {
    weak var target: AudioPlaybackController?
    init(target: AudioPlaybackController) { self.target = target }
    // CADisplayLink 添加到 `.main` runloop，fire 天然在主线程上——用 `assumeIsolated` 把编译器
    // 的 `@MainActor` 隔离检查满足掉，无需付一次 Task 切换 / hop 开销。
    @objc func tick() {
        MainActor.assumeIsolated {
            target?.updateProgress()
        }
    }
}
#endif

// 新的音频播放控制器
//
// **@MainActor 强制**：这个 class 有一堆 @Published 属性，Swift 6 strict 下从非主线程改
// 会 hard-crash ("Publishing changes from background threads is not allowed")。
// `AVAudioPlayerDelegate` 的回调（didFinishPlaying / decodeErrorDidOccur）**Apple 不保证**
// 主线程触发——某些 iOS 版本/codec 会从底层 audio 队列线程直接调进来。
// 做法：整个类 @MainActor，delegate 方法用 `nonisolated` 接受底层回调后立刻 hop 回 main。
@MainActor
final class AudioPlaybackController: NSObject, AVAudioPlayerDelegate, ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var progress: Double = 0.0 // 0.0 to 1.0
    @Published var duration: TimeInterval = 0.0
    @Published var currentTime: TimeInterval = 0.0
    @Published private(set) var currentPlayingFileName: String? // 用于确保只操作当前音频. private(set) 外部只读

    private var audioPlayer: AVAudioPlayer?
#if canImport(UIKit)
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
#else
    private var progressTimer: Timer?
#endif

    var onFinishPlaying: (() -> Void)?
    var onPlayError: ((Error) -> Void)?

    func play(url: URL, fileName: String) {
        if let player = audioPlayer, player.isPlaying, currentPlayingFileName == fileName {
            player.pause()
            isPlaying = false
            stopDisplayLink()
            return
        }
        if let player = audioPlayer, !player.isPlaying, currentPlayingFileName == fileName {
            player.play()
            isPlaying = true
            startDisplayLink()
            return
        }

        stopPlayback(clearCurrentFile: false) // 停止之前的播放，但不清除 currentPlayingFileName

        currentPlayingFileName = fileName // 在这里设置当前播放文件名
        do {
#if canImport(UIKit)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
#endif

            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            duration = audioPlayer?.duration ?? 0.0
            currentTime = 0.0
            progress = 0.0
            audioPlayer?.play()
            isPlaying = true
            startDisplayLink()
        } catch {
            Log.error("[AudioPlaybackController] Could not play audio: \\(error)", category: .ui)
            onPlayError?(error)
            stopPlaybackCleanup() // 出错时彻底清理
        }
    }

    func pause() {
        guard let player = audioPlayer, player.isPlaying else { return }
        player.pause()
        isPlaying = false
        stopDisplayLink()
    }

    func stopPlayback(clearCurrentFile: Bool = true) {
        audioPlayer?.stop()
        isPlaying = false
        if clearCurrentFile {
             currentPlayingFileName = nil
        }
        stopDisplayLink()
        if audioPlayer != nil {
            do {
#if canImport(UIKit)
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
            } catch {
                Log.error("[AudioPlaybackController] Could not deactivate audio session: \\(error)", category: .ui)
            }
            audioPlayer = nil
        }
    }

    private func stopPlaybackCleanup() {
        isPlaying = false
        stopDisplayLink()
        if audioPlayer != nil {
            do {
#if canImport(UIKit)
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
            } catch {
                Log.error("[AudioPlaybackController] Could not deactivate audio session on cleanup: \\(error)", category: .ui)
            }
             audioPlayer = nil
        }
        onFinishPlaying?()
    }

    @objc fileprivate func updateProgress() {
        guard let player = audioPlayer else {
            if isPlaying { isPlaying = false; stopDisplayLink() }
            return
        }
        // 确保只有在播放时才更新进度和时间
        if player.isPlaying {
            currentTime = player.currentTime
            if duration > 0 {
                progress = player.currentTime / duration
            } else {
                progress = 0
            }
        } else {
            // 如果播放器没有在播放 (例如暂停了)，停止 displayLink
            if isPlaying { // 如果状态错误地认为还在播放
                isPlaying = false
            }
            stopDisplayLink()
        }
    }

    private func startDisplayLink() {
#if canImport(UIKit)
        // 每次 start 都是全新 CADisplayLink——stopDisplayLink 现在真的 invalidate 了，
        // 不再复用之前的 paused 实例。这样 runloop 里不会累积"暂停的僵尸 display link"。
        let proxy = DisplayLinkProxy(target: self)
        displayLinkProxy = proxy
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        // 限制刷新率到 30fps，平衡 UI 流畅度和 CPU 占用
        link.preferredFrameRateRange = CAFrameRateRange.uiUpdates
        link.add(to: .main, forMode: .common)
        displayLink = link
#else
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0/15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateProgress() }
        }
#endif
    }

    private func stopDisplayLink() {
#if canImport(UIKit)
        // 之前只 `isPaused = true`——CADisplayLink 还留在 runloop 上，proxy 也还在 retain 它。
        // 一旦 controller 因为 deinit 没被触发（retain cycle 或 closure 捕 self），link 就永不消失。
        // 彻底 invalidate + 丢引用，下次 start 时重建。
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
#else
        progressTimer?.invalidate()
        progressTimer = nil
#endif
    }

    // AVAudioPlayerDelegate 的回调 Apple 不保证主线程触发——nonisolated 接底层，然后
    // 显式 hop 回 @MainActor 做状态更新。Swift 6 下从后台改 @Published 会 hard-crash。
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            Log.info("[AudioPlaybackController] Audio finished playing. Success: \(flag)", category: .ui)
            self.progress = 1.0
            self.currentTime = self.duration
            self.stopPlaybackCleanup()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if let error = error {
                Log.error("[AudioPlaybackController] Audio player decode error: \(error.localizedDescription)", category: .ui)
                self.onPlayError?(error)
            }
            self.stopPlaybackCleanup()
        }
    }

    deinit {
        // 说明：class 打了 @MainActor，但 deinit 运行线程 Swift 不保证——
        // 这里的所有操作都用"非 actor-isolated API 即可（Timer.invalidate / AVAudioPlayer.stop 都是线程安全）。
        // 不能访问 `displayLinkProxy` / `audioPlayer` 等隔离属性——所以拿一份局部引用快照。
#if canImport(UIKit)
        let linkToKill = displayLink
        let proxyToKill = displayLinkProxy
        linkToKill?.invalidate()
        _ = proxyToKill  // 持到 deinit 末尾，避免提前释放 mid-invalidate
#else
        progressTimer?.invalidate()
#endif
        audioPlayer?.stop()
        Log.info("[AudioPlaybackController] deinit", category: .ui)
    }
}
