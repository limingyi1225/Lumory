import Foundation
import AVFoundation
import SwiftUI

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    // 高频电平/时长不走 @Published：录音时 20Hz 广播会让整个 HomeView 跟着重绘，
    // 视觉上反而卡。录音状态条用自己的轻量刷新循环读取这两个值。
    private(set) var amplitude: Float = 0 // 0.0 ~ 1.0 之间，代表当前音量大小
    /// 中断 (电话 / Siri / 其他音频) 后被自动停下、且时长 ≥ 0.5s 已落盘的录音文件名。
    /// HomeView observe 这个 @Published,把文件名接进 audioRecordings 让用户看到录到的段落,
    /// 避免中断把已录的内容默默丢掉。HomeView 消费后置 nil。
    @Published var interruptedRecordingFileName: String?
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
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .undetermined:
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
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .undetermined:
                pendingPermissionToken &+= 1
                let myToken = pendingPermissionToken
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
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
        }
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

            // 开始录制
            recorder?.record()
            startTime = Date()
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
            RunLoop.current.add(timer, forMode: .common)
            meterTimer = timer
            timerLock.unlock()
            // NOTE：这里不用 defer 是因为后面还有 setActive / record 等可能抛异常的调用位于 lock 外，
            // 我们**需要** unlock 在 timer 装好后立即发生，defer 会把它推迟到 func 返回。

            isRecording = true
            Log.info("[AudioRecorder] Recording started. File URL: \(url.path)", category: .audio)
            return true
        } catch {
            Log.error("[AudioRecorder] Could not start recording: \(error)", category: .audio)
            return false
        }
    }

    func stopRecording() -> String? {
        // 先截取出 recorder 引用，让锁的作用域尽量短——后续 File I/O / Log 都不用持锁。
        recorderLock.lock()
        let captured: AVAudioRecorder? = self.recorder
        recorderLock.unlock()

        guard let recorder = captured else { return nil }
        #if !os(macOS)
        defer {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif

        recorder.stop()

        var recordedDuration: TimeInterval = 0
        if let start = startTime {
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
            // 中断结束不自动续录；让用户自己决定是否再开一段
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
        // 尽力归还音频路由，失败也无所谓（session 可能已被销毁）
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
