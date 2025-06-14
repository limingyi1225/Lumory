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
    private var pausedTime: TimeInterval = 0
    @Published var isPaused = false
    
    // Thread safety
    private let recorderLock = NSLock()
    private let timerLock = NSLock()

    func startRecording() {
        do {
            #if !os(macOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true)
            print("[AudioRecorder] Audio session configured successfully")
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

            // 启动计时器，定期更新音量数据（selector-based）
            timerLock.lock()
            meterTimer = Timer.scheduledTimer(timeInterval: 0.03,
                                             target: self,
                                             selector: #selector(handleMeter(_:)),
                                             userInfo: nil,
                                             repeats: true)
            // Ensure timer runs on common run loop mode
            if let timer = meterTimer {
                RunLoop.current.add(timer, forMode: .common)
            }
            timerLock.unlock()

            isRecording = true
            print("[AudioRecorder] Recording started. File URL: \(url.path)")
        } catch {
            print("[AudioRecorder] Could not start recording: \(error)")
        }
    }

    func stopRecording() -> String? {
        recorderLock.lock()
        guard let recorder else {
            recorderLock.unlock()
            return nil
        }
        
        // Resume if paused before stopping
        if isPaused {
            recorder.record()
            isPaused = false
        }
        
        recorder.stop()
        recorderLock.unlock()

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
        
        // 如果录音时长小于0.5秒，则删除录音文件并返回nil
        if recordedDuration < 0.5 {
            let url = recorder.url
            try? FileManager.default.removeItem(at: url)
            print("[AudioRecorder] Recording too short (\(recordedDuration)s), deleted file")
            return nil
        }
        
        let url = recorder.url
        let fileName = url.lastPathComponent
        print("[AudioRecorder] Recording stopped. Duration: \(recordedDuration)s, File: \(fileName), Path: \(url.path)")
        print("[AudioRecorder] File exists: \(FileManager.default.fileExists(atPath: url.path))")
        
        return fileName
    }
    
    func pauseRecording() {
        guard let recorder = recorder, isRecording, !isPaused else { return }
        recorder.pause()
        isPaused = true
        
        // Stop the meter timer while paused
        timerLock.lock()
        meterTimer?.invalidate()
        meterTimer = nil
        timerLock.unlock()
        amplitude = 0
    }
    
    func resumeRecording() {
        guard let recorder = recorder, isRecording, isPaused else { return }
        recorder.record()
        isPaused = false
        
        // Restart the meter timer
        timerLock.lock()
        meterTimer = Timer.scheduledTimer(timeInterval: 0.03,
                                         target: self,
                                         selector: #selector(handleMeter(_:)),
                                         userInfo: nil,
                                         repeats: true)
        if let timer = meterTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
        timerLock.unlock()
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

    @objc private func handleMeter(_ timer: Timer) {
        recorderLock.lock()
        guard let recorder = recorder else {
            recorderLock.unlock()
            return
        }
        recorder.updateMeters()
        let power = recorder.peakPower(forChannel: 0) // 使用峰值更灵敏
        recorderLock.unlock()
        
        let level = normalizedPower(power)
        // Update published property on main thread
        Task { @MainActor in
            self.amplitude = level
        }
    }
    
    deinit {
        // Ensure timer cleanup happens on main thread
        if Thread.isMainThread {
            timerLock.lock()
            meterTimer?.invalidate()
            meterTimer = nil
            timerLock.unlock()
        } else {
            DispatchQueue.main.sync {
                timerLock.lock()
                meterTimer?.invalidate()
                meterTimer = nil
                timerLock.unlock()
            }
        }
        
        recorderLock.lock()
        recorder?.stop()
        recorder = nil
        recorderLock.unlock()
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("[AudioRecorder] Recording failed.")
        } else {
            print("[AudioRecorder] Recording finished successfully")
        }
    }
    
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("[AudioRecorder] Encoding error: \(error.localizedDescription)")
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