import Foundation
import AVFoundation
import SwiftUI

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var amplitude: Float = 0 // 0.0 ~ 1.0 之间，代表当前音量大小
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startTime: Date?
    @Published var duration: TimeInterval = 0
    /// 已累计的暂停总时长（秒）。计算真实录音时长时 `Date().timeIntervalSince(startTime) - pausedTime`。
    private var pausedTime: TimeInterval = 0
    /// 本次暂停开始的时刻。resume 时用 `Date().timeIntervalSince(pauseStart)` 累加进 `pausedTime`。
    private var pauseStart: Date?
    @Published var isPaused = false

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

    func startRecording() {
        guard !isRecording else {
            Log.warning("[AudioRecorder] startRecording called while already recording — ignoring", category: .audio)
            return
        }
        do {
            #if !os(macOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true)
            Log.info("[AudioRecorder] Audio session configured successfully", category: .audio)
            #endif

            let filename = UUID().uuidString + ".m4a"
            let url = getAudioURL(for: filename)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 12000,
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
            pausedTime = 0

            // 启动计时器，定期更新音量数据（使用闭包避免内存泄漏）。
            // 改成手动 init + 单次 RunLoop.add(.common)：原来的 scheduledTimer 已经自动
            // 注册到 .default mode，再 add(.common) 会被双重注册，造成每 tick 双触发。
            timerLock.lock()
            let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
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
            pauseStart = nil
            Log.info("[AudioRecorder] Recording started. File URL: \(url.path)", category: .audio)
        } catch {
            Log.error("[AudioRecorder] Could not start recording: \(error)", category: .audio)
        }
    }

    func stopRecording() -> String? {
        // 先截取出 recorder 引用，让锁的作用域尽量短——后续 File I/O / Log 都不用持锁。
        recorderLock.lock()
        let captured: AVAudioRecorder? = self.recorder
        let wasPaused = isPaused
        recorderLock.unlock()

        guard let recorder = captured else { return nil }

        if wasPaused {
            // stop 之前还在暂停状态：先把暂停段累加进 pausedTime 再让 recorder 过一遍 record→stop，
            // 否则 `recordedDuration` 会包含这段最后的暂停空档
            if let start = pauseStart {
                pausedTime += Date().timeIntervalSince(start)
                pauseStart = nil
            }
            recorder.record()
            recorderLock.lock()
            isPaused = false
            recorderLock.unlock()
        }

        recorder.stop()

        var recordedDuration: TimeInterval = 0
        if let start = startTime {
            recordedDuration = Date().timeIntervalSince(start) - pausedTime
            duration = recordedDuration
        }
        timerLock.lock()
        meterTimer?.invalidate()
        meterTimer = nil
        timerLock.unlock()
        amplitude = 0
        isRecording = false
        isPaused = false
        pausedTime = 0
        pauseStart = nil
        
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

        // 归还系统音频路由：挂起的音乐/播客会在这之后自动恢复播放。
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

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
                _ = stopRecording()
                Log.info("[AudioRecorder] Interruption began — stopped recording", category: .audio)
            }
        case .ended:
            // 中断结束不自动续录；让用户自己决定是否再开一段
            break
        @unknown default:
            break
        }
    }
    #endif
    
    func resumeRecording() {
        guard let recorder = recorder, isRecording, isPaused else { return }
        // 把刚刚这段暂停的秒数累加到 pausedTime，让后续 duration 计算能把空档抵消掉
        if let start = pauseStart {
            pausedTime += Date().timeIntervalSince(start)
            pauseStart = nil
        }
        recorder.record()
        isPaused = false

        // 必须跟 startRecording 里一样：`Timer.init` + 单次 `RunLoop.add(.common)`。
        // 之前用 `Timer.scheduledTimer` 已经把 timer 注册到了 `.default` mode，再 `add(.common)`
        // 会让它在同一个 tick 下双触发 handleMeterUpdate，暂停恢复后 meter 抖动 + 主线程被拉满。
        timerLock.lock()
        defer { timerLock.unlock() }
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handleMeterUpdate()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        meterTimer = timer
    }

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

    /// 更新音量表读数（闭包版 Timer 调用）。顺手把 duration 也推一下，
    /// 否则 UI 里绑 `recorder.duration` 的录音时长只会在停止时才更新一次。
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
        if let start = startTime, !isPaused {
            elapsed = Date().timeIntervalSince(start) - pausedTime
        } else {
            elapsed = duration
        }
        // Update published properties on main thread
        Task { @MainActor in
            self.amplitude = level
            self.duration = elapsed
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

// MARK: - Cleanup
extension AudioRecorder {
    func cleanup() {
        timerLock.lock()
        meterTimer?.invalidate()
        meterTimer = nil
        timerLock.unlock()
        
        recorderLock.lock()
        recorder?.stop()
        recorder = nil
        recorderLock.unlock()
        
        isRecording = false
        isPaused = false
        amplitude = 0
    }
} 