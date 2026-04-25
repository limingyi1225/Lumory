import Speech
import AVFoundation

// MARK: - Transcriber Contract
//
// 把"转录"抽象成协议，让 caller 能注入 mock 做测试。线上实现是
// AppleSpeechRecognizer，测试侧可用 MockTranscriber（在 AIService.swift）。

@MainActor
protocol TranscriberProtocol: AnyObject {
    var lastFailure: TranscriptionFailure? { get }
    func transcribeAudio(fileURL: URL, localeIdentifier: String) async -> String?
}

enum TranscriptionFailure: Equatable {
    case speechPermissionDenied
    case speechPermissionRestricted
    case recognizerUnavailable
    case unsupportedOnDeviceLocale
    case recognitionFailed

    var shouldOfferSettings: Bool {
        switch self {
        case .speechPermissionDenied, .speechPermissionRestricted:
            return true
        case .recognizerUnavailable, .unsupportedOnDeviceLocale, .recognitionFailed:
            return false
        }
    }
}

@available(iOS 13.0, macOS 10.15, *)
@MainActor
final class AppleSpeechRecognizer: TranscriberProtocol {
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private(set) var lastFailure: TranscriptionFailure?

    deinit {
        // 原来没有 deinit：视图被释放但 `recognitionTask` 还挂着 Speech framework，
        // 导致麦克风和 SFSpeechRecognitionTask 在后台继续活，直到 OS 超时才放。
        recognitionTask?.cancel()
        recognitionTask = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    func transcribeAudio(fileURL: URL, localeIdentifier: String) async -> String? {
        Log.info("[AppleSpeechRecognizer] Starting transcription for file: \(fileURL.path)", category: .ai)
        Log.info("[AppleSpeechRecognizer] File exists: \(FileManager.default.fileExists(atPath: fileURL.path))", category: .ai)
        lastFailure = nil
        
        // 检查并请求授权
        let authStatus = await requestAuthorization()
        Log.info("[AppleSpeechRecognizer] Authorization status: \(authStatus.rawValue)", category: .ai)
        
        guard authStatus == .authorized else {
            Log.info("[AppleSpeechRecognizer] Speech recognition not authorized.", category: .ai)
            switch authStatus {
            case .denied:
                lastFailure = .speechPermissionDenied
            case .restricted:
                lastFailure = .speechPermissionRestricted
            default:
                lastFailure = .recognitionFailed
            }
            return nil
        }
        
        // 根据用户选择的语言初始化 SFSpeechRecognizer
        let locale = Locale(identifier: localeIdentifier)
        Log.info("[AppleSpeechRecognizer] Using locale: \(locale.identifier)", category: .ai)
        speechRecognizer = SFSpeechRecognizer(locale: locale)

        guard let recognizer = speechRecognizer else {
            Log.error("[AppleSpeechRecognizer] Failed to create speech recognizer", category: .ai)
            lastFailure = .recognizerUnavailable
            return nil
        }
        
        guard recognizer.isAvailable else {
            Log.info("[AppleSpeechRecognizer] Speech recognizer is not available for locale: \(locale.identifier)", category: .ai)
            lastFailure = .recognizerUnavailable
            return nil
        }
        
        Log.info("[AppleSpeechRecognizer] Speech recognizer is available", category: .ai)

        // 验证文件是否可读
        do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileSize = fileAttributes[.size] as? Int64 ?? 0
            Log.info("[AppleSpeechRecognizer] Audio file size: \(fileSize) bytes", category: .ai)
            
            // 检查文件是否可播放
            let asset = AVURLAsset(url: fileURL)
            let playable = try await asset.load(.isPlayable)
            Log.info("[AppleSpeechRecognizer] Audio file is playable: \(playable)", category: .ai)
        } catch {
            Log.error("[AppleSpeechRecognizer] Error checking file: \(error)", category: .ai)
        }
        
        let failureBox = LockWrap<TranscriptionFailure?>(nil)
        let transcript = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                let request = SFSpeechURLRecognitionRequest(url: fileURL)
                request.shouldReportPartialResults = false // 我们只需要最终结果
                request.addsPunctuation = true // 添加标点符号
                // **隐私约束**：Info.plist 里的 `NSMicrophoneUsageDescription` 明确声明
                // "录音只在本地处理，不上传第三方"。默认情况下 SFSpeechRecognizer 会回落
                // 到 Apple 云端识别（尤其是 locale 不支持 on-device 或 on-device 质量低时）。
                // 强制 requiresOnDeviceRecognition 对不支持的 locale 会直接失败——宁可
                // 转录失败也不违背隐私声明。主流 locale（en-*/zh-*/ja-*/ko-*）都支持。
                if recognizer.supportsOnDeviceRecognition {
                    request.requiresOnDeviceRecognition = true
                } else {
                    Log.info("[AppleSpeechRecognizer] Locale \(localeIdentifier) 不支持 on-device，拒绝转录以兑现隐私声明", category: .ai)
                    failureBox.set(.unsupportedOnDeviceLocale)
                    continuation.resume(returning: nil)
                    return
                }

                // **resume 恰好一次保护**：
                // SFSpeechRecognitionTask 的回调有三条路径——
                //   (a) result == nil → 我们 resume(nil)
                //   (b) result != nil + isFinal → 我们 resume(transcription)
                //   (c) result != nil + !isFinal → **原实现什么都没做**
                // 尽管 shouldReportPartialResults = false 理论上会避免 (c)，但：
                //   - 某些 locale / iOS 版本会忽略该旗标
                //   - 带 error 的非 final 回调会双重命中（result 非 nil、error 也非 nil）
                // 漏掉的 continuation 直接让 HomeView 的保存按钮永久 spin。
                // 用本地 once flag 保证 resume 恰好一次；多次回调静默忽略。
                let didResume = LockWrap(false)
                func safeResume(_ value: String?) {
                    didResume.lock.lock()
                    defer { didResume.lock.unlock() }
                    guard !didResume.value else { return }
                    didResume.value = true
                    continuation.resume(returning: value)
                }

                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error = error {
                        Log.error("[AppleSpeechRecognizer] Recognition error: \(error.localizedDescription)", category: .ai)
                        failureBox.set(.recognitionFailed)
                        safeResume(nil)
                        return
                    }
                    guard let result = result else {
                        Log.error("[AppleSpeechRecognizer] Recognition returned nil result with no error", category: .ai)
                        failureBox.set(.recognitionFailed)
                        safeResume(nil)
                        return
                    }
                    if result.isFinal {
                        let transcription = result.bestTranscription.formattedString
                        Log.info("[AppleSpeechRecognizer] Transcription successful", category: .ai)
                        safeResume(transcription)
                    }
                    // 非 final 且无 error：等下一次回调。safeResume 不会错误触发。
                }
                self.recognitionTask = task
            }
        } onCancel: { [weak self] in
            // Task 被取消时（视图消失 / swipe back）立即释放麦克风与 Speech framework。
            Task { @MainActor in
                self?.recognitionTask?.cancel()
            }
        }
        if transcript == nil {
            let failure = failureBox.get()
            if let failure {
                lastFailure = failure
            }
        }
        return transcript
    }

    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authStatus in
                continuation.resume(returning: authStatus)
            }
        }
    }
}

/// 包一个 value + NSLock 的小容器，让闭包里能做"一次性 resume"守卫——
/// struct 值类型 + closure 捕获时不能原地改，用 class 包一层拿到引用语义。
private final class LockWrap<T> {
    var value: T
    let lock = NSLock()
    init(_ value: T) { self.value = value }

    func set(_ newValue: T) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
