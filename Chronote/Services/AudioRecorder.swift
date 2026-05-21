import Foundation
import AVFoundation
import SwiftUI

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    nonisolated static let maximumDuration: TimeInterval = 10 * 60

    struct CompletedRecording: Equatable {
        let fileName: String
        let duration: TimeInterval
    }

    @Published var isRecording = false
    /// (A-05 / G-03 superreview 2026-05-19, 防御性硬化)
    ///
    /// `handleMeterUpdate` 每 50ms fire 一次,内部走"if elapsed >= 600 && isRecording → stopRecording"。
    /// 静态分析下当前实现安全(`startRecording()` 同步覆写 `startTime = Date()` + `isRecording = true`
    /// 在同一帧;新一轮录音 elapsed ≈ 0,guard 不会重新触发),**但**:
    /// - level-trigger guard 比 edge-trigger 容易在未来 refactor 上回归(只要 someone 把 startTime
    ///   不复位 / isRecording 复位顺序改了,就立刻 stale-fire 新录音)。
    /// - 多个 tick 已 enqueue 到 main actor 时,本帧停录之后下一帧的 stale tick 仍会跑;edge-trigger
    ///   让"本轮已自动停止过"明确不再重复触发。
    /// 边沿信号:仅在 `startRecording()` 入口重置为 false,自动停止触发后置 true,在 tick guard 里
    /// 一并 check。
    private var didFireMaxDurationStop: Bool = false
    // 高频电平/时长不走 @Published：录音时 20Hz 广播会让整个 HomeView 跟着重绘，
    // 视觉上反而卡。录音状态条用自己的轻量刷新循环读取这两个值。
    private(set) var amplitude: Float = 0 // 0.0 ~ 1.0 之间，代表当前音量大小
    /// 中断 (电话 / Siri / 其他音频) 后被自动停下、且时长 ≥ 0.5s 已落盘的录音文件名。
    /// HomeView observe 这个 @Published,把文件名接进 audioRecordings 让用户看到录到的段落,
    /// 避免中断把已录的内容默默丢掉。HomeView 消费后置 nil。
    @Published var interruptedRecordingFileName: String?
    @Published var maxDurationRecording: CompletedRecording?
    /// 标记当前是否在等待权限授权回调。**用 token 防 stale grant 误启**:用户点 mic → 弹 alert
    /// → 在用户做选择之前 navigate 走 / 切 view → 老 grant 回调到 .granted 时,startRecording
    /// 已经不该跑了。token 不一致就 abort。
    private var pendingPermissionToken: Int = 0
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startTime: Date?
    private(set) var duration: TimeInterval = 0

    // Thread safety
    private let recorderLock = NSLock()
    private let timerLock = NSLock()

    // 录音时打开的 session，stop 之后要 `.notifyOthersOnDeactivation` 归还系统音频路由，
    // 否则背景的音乐/播客/电话挂断后不会自动恢复。
    #if !os(macOS)
    private var interruptionObserver: NSObjectProtocol?
    #endif

    override init() {
        super.init()
        #if !os(macOS)
        // 注册电话/其他 app 中断通知，挂断时我们自己停录音
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleInterruption(notification)
            }
        }
        #endif
    }

    /// 开始录音。返回 `true` iff 立即开始了录制。返回 `false` 表示:
    ///   - 权限未定 → 弹系统 alert,用户允许后**自动续录**(token-guarded);拒绝 → 不录
    ///   - 权限被拒 → 不录
    ///   - 配置失败 → 不录
    /// 调用方据此决定是否发"已开始录"的 success haptic — 这一刻没真开始就别发,
    /// 后续 grant 后的自动续录由 isRecording @Published 自动驱动 UI(stop 图标 / 计时器 / 波形都跟 isRecording)。
    @discardableResult
    func startRecording() -> Bool {
        guard !isRecording else {
            Log.warning("[AudioRecorder] startRecording called while already recording — ignoring", category: .audio)
            return false
        }
        #if !os(macOS)
        // 部署目标 iOS 26.0,直接用 iOS 17+ AVAudioApplication API。
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            // (2026-05-19 superreview P1-2)Screenshot 自动化模式:跳过权限弹窗,否则
            // iOS 系统 alert 会盖到 Home 上把首屏截烂。原先 ChronoteApp.requestPermissions
            // 启动时跳的 guard 已删,要在这里补 — startRecording 是新的唯一权限请求入口。
            #if DEBUG
            if UITestSampleData.isActive {
                Log.info("[AudioRecorder] startRecording: skipping permission prompt in screenshot mode", category: .audio)
                return false
            }
            #endif
            pendingPermissionToken &+= 1
            let myToken = pendingPermissionToken
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // token 不一致 = 用户在 alert 弹出后已经离开了"我要录音"的意图。
                    guard self.pendingPermissionToken == myToken else {
                        Log.info("[AudioRecorder] Late mic grant ignored (token stale)", category: .audio)
                        return
                    }
                    guard granted else {
                        Log.warning("[AudioRecorder] Microphone permission denied", category: .audio)
                        return
                    }
                    Log.info("[AudioRecorder] Mic permission granted — auto-starting recording", category: .audio)
                    self.startRecording()
                }
            }
            return false
        case .denied:
            Log.warning("[AudioRecorder] Microphone permission denied", category: .audio)
            return false
        case .granted:
            break
        @unknown default:
            Log.warning("[AudioRecorder] Unknown microphone permission status", category: .audio)
            return false
        }
        #endif
        #if !os(macOS)
        var didActivateAudioSession = false
        #endif
        do {
            #if !os(macOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
            )
            try audioSession.setActive(true)
            didActivateAudioSession = true
            Log.info("[AudioRecorder] Audio session configured successfully", category: .audio)
            #endif

            let filename = UUID().uuidString + ".m4a"
            let url = getAudioURL(for: filename)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self

            // 启用分贝检测
            recorder?.isMeteringEnabled = true

            // 开始录制 — `record()` 返 Bool,false 表示系统拒录(权限被吊销 / audio session 抢占失败 /
            // 磁盘满)。不 check 返回值会让 UI 进 isRecording=true + meter 跑,实际生成 0 字节 m4a。
            guard recorder?.record() == true else {
                Log.error("[AudioRecorder] AVAudioRecorder.record() returned false; aborting startRecording", category: .audio)
                recorder = nil
                #if !os(macOS)
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                #endif
                return false
            }
            startTime = Date()
            didFireMaxDurationStop = false   // A-05 / G-03 edge-trigger reset 必须跟 startTime 一组
            duration = 0

            // 启动计时器，定期更新音量数据（使用闭包避免内存泄漏）。
            // 改成手动 init + 单次 RunLoop.add(.common)：原来的 scheduledTimer 已经自动
            // 注册到 .default mode，再 add(.common) 会被双重注册，造成每 tick 双触发。
            timerLock.lock()
            // 0.03 → 0.05(33Hz → 20Hz)。这里仍保持录音电平采样灵敏；UI 侧不再用 @Published
            // 订阅这个频率，而是只让录音小控件自己拉取当前 snapshot。
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.handleMeterUpdate()
                }
            }
            // RunLoop.main 显式,不用 .current —— startRecording 当前 @MainActor 保证 current
            // 等于 main,但任何 future `MainActor.assumeIsolated` 调用路径会让 .current 是别的
            // RunLoop,timer 静默不 fire。`ThemeAliasResolver.scheduleCoolUntilExpiry` 已经是这个
            // pattern,这里对齐。(2026-05-15 megareview P2-7)
            RunLoop.main.add(timer, forMode: .common)
            meterTimer = timer
            timerLock.unlock()
            // NOTE：这里不用 defer 是因为后面还有 setActive / record 等可能抛异常的调用位于 lock 外，
            // 我们**需要** unlock 在 timer 装好后立即发生，defer 会把它推迟到 func 返回。

            isRecording = true
            Log.info("[AudioRecorder] Recording started. File URL: \(url.path)", category: .audio)
            return true
        } catch {
            Log.error("[AudioRecorder] Could not start recording: \(error)", category: .audio)
            #if !os(macOS)
            if didActivateAudioSession {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            #endif
            return false
        }
    }

    func stopRecording() -> String? {
        // 单次消费 recorder,让连续 stop / 中断回调 / max-duration tick 只能拿到一次有效结果。
        recorderLock.lock()
        let captured: AVAudioRecorder? = self.recorder
        self.recorder = nil
        let capturedStartTime = self.startTime
        self.startTime = nil
        recorderLock.unlock()

        guard let recorder = captured else { return nil }
        #if !os(macOS)
        defer {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif

        recorder.stop()

        var recordedDuration: TimeInterval = 0
        if let start = capturedStartTime {
            recordedDuration = Date().timeIntervalSince(start)
            duration = recordedDuration
        }
        timerLock.lock()
        meterTimer?.invalidate()
        meterTimer = nil
        timerLock.unlock()
        amplitude = 0
        isRecording = false

        // 如果录音时长小于0.5秒，则删除录音文件并返回nil
        if recordedDuration < 0.5 {
            let url = recorder.url
            try? FileManager.default.removeItem(at: url)
            Log.info("[AudioRecorder] Recording too short (\(recordedDuration)s), deleted file", category: .audio)
            return nil
        }

        let url = recorder.url
        let fileName = url.lastPathComponent
        Log.info("[AudioRecorder] Recording stopped. Duration: \(recordedDuration)s, File: \(fileName), Path: \(url.path)", category: .audio)
        Log.info("[AudioRecorder] File exists: \(FileManager.default.fileExists(atPath: url.path))", category: .audio)

        return fileName
    }

    /// 处理 AVAudioSession 中断（电话进来、其他 app 抢占麦克风等）。
    /// 原实现完全没注册这个通知：中断后 recorder 被系统停掉但我们不知道，
    /// `isRecording` 仍是 true，UI timer 继续跑，但实际没在录。最终保存的文件是截断的。
    #if !os(macOS)
    @MainActor
    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // 中断开始：停止录音、把已录的段落保留给用户
            if isRecording {
                let filename = stopRecording()
                if let filename {
                    // **关键**:把 filename 透出给 HomeView。stopRecording 内部已经处理 < 0.5s 删文件
                    // 返 nil 的 case;非 nil 表示文件留在磁盘上,UI 必须能 surface 出来,否则用户的
                    // 录音段落就丢了。HomeView 消费后置 nil。
                    interruptedRecordingFileName = filename
                }
                Log.info("[AudioRecorder] Interruption began — stopped recording (file=\(filename ?? "nil"))", category: .audio)
            }
        case .ended:
            // **不在 .ended reactivate session** — 我们的策略是不自动续录,reactivate 会让进程
            // 占着 play-and-record audio route 不释放(没有 recorder 在跑也 hold 着),干扰其他
            // app 接管 audio。下次用户主动 startRecording 时,内部会调 `setActive(.playAndRecord, ...)`
            // 自己 reactivate,不需要这里提前做。原 megareview finding "interruption ended 不
            // reactivate 会让 startRecording silent failure" 经 codex re-review verify 是 false alarm —
            // startRecording 自己的 setActive 调用足以恢复 session。
            break
        @unknown default:
            break
        }
    }
    #endif

    /// 将 dB 值映射到 0.0~1.0 线性区间
    private func normalizedPower(_ power: Float) -> Float {
        let minDb: Float = -60
        let clamped = max(min(power, 0), minDb)
        return (clamped - minDb) / -minDb
    }

    /// Gets the proper URL for audio storage (always local for temp recordings)
    private func getAudioURL(for fileName: String) -> URL {
        // Always use local documents directory for temporary recordings
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent(fileName)
    }

    /// 更新音量表读数（闭包版 Timer 调用）。这里只更新本地 snapshot，不触发 objectWillChange。
    private func handleMeterUpdate() {
        recorderLock.lock()
        guard let recorder = recorder else {
            recorderLock.unlock()
            return
        }
        recorder.updateMeters()
        let power = recorder.peakPower(forChannel: 0) // 使用峰值更灵敏
        recorderLock.unlock()

        let level = normalizedPower(power)
        let elapsed: TimeInterval
        if let start = startTime {
            elapsed = Date().timeIntervalSince(start)
        } else {
            elapsed = duration
        }
        amplitude = level
        duration = elapsed
        if elapsed >= Self.maximumDuration, isRecording, !didFireMaxDurationStop {
            didFireMaxDurationStop = true   // edge-trigger,防止 stale tick 在新一轮录音 re-fire
            if let fileName = stopRecording() {
                maxDurationRecording = CompletedRecording(fileName: fileName, duration: duration)
            }
        }
    }

    deinit {
        // **不要** 假设 MainActor 类的 deinit 在主线程——Swift 6 下 deinit 可在任意线程。
        // Timer.invalidate / NotificationCenter.removeObserver 都是 thread-safe 的，锁也是。

        timerLock.lock()
        let timerToInvalidate = meterTimer
        meterTimer = nil
        timerLock.unlock()
        timerToInvalidate?.invalidate()

        recorderLock.lock()
        recorder?.stop()
        recorder = nil
        recorderLock.unlock()

        #if !os(macOS)
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // **不在 deinit 调 `AVAudioSession.setActive(false)`** — session 是 process-shared 单例,
        // `AudioPlaybackController` 可能正持有 active session 播一段录音,deinit 路径关 session 会让
        // 那边的播放无声中断。`stopRecording()` 内部 defer 已经在录制结束的"正常"路径关 session,
        // deinit 是"recorder 没 stopRecording 就被 dealloc"的边角 case(app 被 jetsam 或调用方忘 stop),
        // 那种场景下进程级 session 状态轮不到 recorder 单独管。
        #endif
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            Log.error("[AudioRecorder] Recording failed.", category: .audio)
        } else {
            Log.info("[AudioRecorder] Recording finished successfully", category: .audio)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            Log.error("[AudioRecorder] Encoding error: \(error.localizedDescription)", category: .audio)
        }
    }
}
