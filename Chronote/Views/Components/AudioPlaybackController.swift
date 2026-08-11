import AVFoundation
import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 单个时间点 → `M:SS`(不补前导零的分钟,跟系统播放器 / 语音备忘录一致)。
/// 播放器用"已播 / 剩余"两端读数,不再用 `formattedDuration` 那种 `00:14 / 01:23` 合并串。
func formattedTimestamp(_ time: TimeInterval) -> String {
    let total = Int(max(0, time.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
}

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
            deactivateAudioSession(reason: "pause")
            return
        }
        if let player = audioPlayer, !player.isPlaying, currentPlayingFileName == fileName {
            // (2026-05-15 megareview P2-5)resume 时重新激活 audio session。期间其他 App
            // (电话 / 视频 / 媒体 App)可能已 deactivate 共享 session,直接 player.play() 在 inactive
            // session 上无声音。重激活后再 play。
            #if canImport(UIKit)
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                Log.warning("[AudioPlaybackController] resume: session reactivate failed: \(error)", category: .ui)
                onPlayError?(error)
                stopPlayback(clearCurrentFile: true)
                return
            }
            #endif
            guard player.play() else {
                let error = Self.playbackStartError()
                Log.error("[AudioPlaybackController] resume play() returned false for \(fileName)", category: .ui)
                onPlayError?(error)
                stopPlayback(clearCurrentFile: true)
                return
            }
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
            guard audioPlayer?.play() == true else {
                let error = Self.playbackStartError()
                Log.error("[AudioPlaybackController] play() returned false for \(fileName)", category: .ui)
                onPlayError?(error)
                currentPlayingFileName = nil
                stopPlaybackCleanup()
                return
            }
            isPlaying = true
            startDisplayLink()
        } catch {
            Log.error("[AudioPlaybackController] Could not play audio: \(error)", category: .ui)
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

    /// 只加载不播放 —— 让用户**在按播放之前就能拖进度条**。
    ///
    /// 没有这条的话,进度条在首次播放前 `audioPlayer == nil`,`seek` 无处可去,用户拖了没反应。
    /// 幂等:同一个 fileName 且 player 还在就直接返回,不会打断正在播放的音频。
    /// 正常纯预加载**不激活 audio session**，不抢别的 App 的音频焦点；session 激活留给
    /// 真正的 `play()`。唯一例外是替换本 controller 正在播放的旧 player，此时会先结束旧播放。
    func prepare(url: URL, fileName: String) throws {
        if audioPlayer != nil && currentPlayingFileName == fileName { return }
        // prepare 自己从不激活 AVAudioSession，因此替换一个纯预加载 / 已暂停的 player
        // 也不能无条件 setActive(false)。AVAudioSession 是进程级共享资源，Detail 的独立
        // controller 若在这里停 session，会把 Home 正在播放甚至正在录制的音频一起打断。
        // 只有这个 controller 确实还在播放时，才需要把自己使用中的 session 一并停掉。
        if let existingPlayer = audioPlayer {
            let wasPlaying = existingPlayer.isPlaying || isPlaying
            existingPlayer.stop()
            isPlaying = false
            stopDisplayLink()
            audioPlayer = nil
            if wasPlaying {
                deactivateAudioSession(reason: "prepare replacement")
            }
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            guard player.prepareToPlay() else {
                throw Self.playbackStartError()
            }
            audioPlayer = player
            currentPlayingFileName = fileName
            duration = player.duration
            currentTime = 0
            progress = 0
        } catch {
            Log.error("[AudioPlaybackController] prepare failed for \(fileName): \(error)", category: .ui)
            // prepare 没有激活 session，失败清理只能碰本 controller 的 player / UI state。
            // 这里绝不能复用 stopPlaybackCleanup()；后者会停用进程级 AVAudioSession。
            currentPlayingFileName = nil
            duration = 0
            currentTime = 0
            progress = 0
            isPlaying = false
            stopDisplayLink()
            audioPlayer = nil
            throw error
        }
    }

    /// 拖动进度条后跳转。`AVAudioPlayer.currentTime` 是可写的,播放中直接赋值即可生效,
    /// 不需要 pause → seek → resume 三步(那样会有一声爆音)。
    ///
    /// 播放中 seek 后 displayLink 下一帧就会用新的 `player.currentTime` 覆盖回来,
    /// 所以这里同步写一遍 `currentTime` / `progress` 是给**暂停态**用的 —— 暂停时
    /// displayLink 不跑,不写这两个 UI 就不动。
    func seek(to time: TimeInterval) {
        guard let player = audioPlayer, duration > 0 else { return }
        let clamped = min(max(0, time), duration)
        player.currentTime = clamped
        currentTime = clamped
        progress = clamped / duration
    }

    func stopPlayback(clearCurrentFile: Bool = true) {
        audioPlayer?.stop()
        isPlaying = false
        if clearCurrentFile {
             currentPlayingFileName = nil
        }
        stopDisplayLink()
        // **无条件 setActive(false)** — 之前 guard `if audioPlayer != nil` 让 sequential 调用第二次
        // (audioPlayer 已 nil)skip 这步,session 持续 active,系统其他 audio app(后台 podcast / music)
        // 等几秒 timeout 才接管。重复 setActive(false) 无副作用,值得跨 app 礼貌性。
        deactivateAudioSession(reason: "stop")
        audioPlayer = nil
    }

    /// 收拾 audio session / displayLink / player 状态,**不**触发 `onFinishPlaying`。
    /// 触发位置:`audioPlayerDidFinishPlaying` delegate 自然结束路径。
    /// 历史 bug:catch path 调 `onPlayError` 后 cleanup 又触发 `onFinishPlaying`,UI 看到
    /// "失败 banner + 立刻完成 callback" 两次冲突反馈。修法是把 `onFinishPlaying` 从 cleanup 拆出。
    private func stopPlaybackCleanup() {
        isPlaying = false
        stopDisplayLink()
        // 同 stopPlayback —— 无条件 setActive(false) 让系统其他 audio app 立刻接管。
        deactivateAudioSession(reason: "cleanup")
        audioPlayer = nil
    }

    private func deactivateAudioSession(reason: String) {
        do {
#if canImport(UIKit)
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
        } catch {
            Log.error("[AudioPlaybackController] Could not deactivate audio session on \(reason): \(error)", category: .ui)
        }
    }

    private static func playbackStartError() -> NSError {
        NSError(
            domain: "Lumory.AudioPlayback",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Unable to start audio playback."
            ]
        )
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
            self.onFinishPlaying?()
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
