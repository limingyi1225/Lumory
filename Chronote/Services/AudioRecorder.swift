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

    func startRecording() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default)
            try audioSession.setActive(true)

            let filename = UUID().uuidString + ".m4a"
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(filename)

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
            meterTimer = Timer.scheduledTimer(timeInterval: 0.03,
                                             target: self,
                                             selector: #selector(handleMeter(_:)),
                                             userInfo: nil,
                                             repeats: true)

            isRecording = true
        } catch {
            print("[AudioRecorder] Could not start recording: \(error)")
        }
    }

    func stopRecording() -> String? {
        guard let recorder else { return nil }
        recorder.stop()

        var recordedDuration: TimeInterval = 0
        if let start = startTime {
            recordedDuration = Date().timeIntervalSince(start)
            duration = recordedDuration
        }
        meterTimer?.invalidate()
        meterTimer = nil
        amplitude = 0
        isRecording = false
        
        // 如果录音时长小于0.5秒，则删除录音文件并返回nil
        if recordedDuration < 0.5 {
            let url = recorder.url
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return recorder.url.lastPathComponent
    }

    /// 将 dB 值映射到 0.0~1.0 线性区间
    private func normalizedPower(_ power: Float) -> Float {
        let minDb: Float = -60
        let clamped = max(min(power, 0), minDb)
        return (clamped - minDb) / -minDb
    }

    @objc private func handleMeter(_ timer: Timer) {
        guard let recorder = recorder else { return }
        recorder.updateMeters()
        let power = recorder.peakPower(forChannel: 0) // 使用峰值更灵敏
        let level = normalizedPower(power)
        amplitude = level
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("[AudioRecorder] Recording failed.")
        }
    }
} 