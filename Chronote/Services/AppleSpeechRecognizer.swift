import Speech
import AVFoundation

@available(iOS 13.0, macOS 10.15, *)
class AppleSpeechRecognizer {

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    func transcribeAudio(fileURL: URL, localeIdentifier: String) async -> String? {
        print("[AppleSpeechRecognizer] Starting transcription for file: \(fileURL.path)")
        print("[AppleSpeechRecognizer] File exists: \(FileManager.default.fileExists(atPath: fileURL.path))")
        
        // 检查并请求授权
        await requestAuthorization()

        let authStatus = SFSpeechRecognizer.authorizationStatus()
        print("[AppleSpeechRecognizer] Authorization status: \(authStatus.rawValue)")
        
        guard authStatus == .authorized else {
            print("[AppleSpeechRecognizer] Speech recognition not authorized.")
            return nil
        }
        
        // 根据用户选择的语言初始化 SFSpeechRecognizer
        let locale = Locale(identifier: localeIdentifier)
        print("[AppleSpeechRecognizer] Using locale: \(locale.identifier)")
        speechRecognizer = SFSpeechRecognizer(locale: locale)

        guard let recognizer = speechRecognizer else {
            print("[AppleSpeechRecognizer] Failed to create speech recognizer")
            return nil
        }
        
        guard recognizer.isAvailable else {
            print("[AppleSpeechRecognizer] Speech recognizer is not available for locale: \(locale.identifier)")
            return nil
        }
        
        print("[AppleSpeechRecognizer] Speech recognizer is available")

        // 验证文件是否可读
        do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileSize = fileAttributes[.size] as? Int64 ?? 0
            print("[AppleSpeechRecognizer] Audio file size: \(fileSize) bytes")
            
            // 检查文件是否可播放
            let asset = AVURLAsset(url: fileURL)
            let playable = try await asset.load(.isPlayable)
            print("[AppleSpeechRecognizer] Audio file is playable: \(playable)")
        } catch {
            print("[AppleSpeechRecognizer] Error checking file: \(error)")
        }
        
        return await withCheckedContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: fileURL)
            request.shouldReportPartialResults = false // 我们只需要最终结果
            request.addsPunctuation = true // 添加标点符号

            recognizer.recognitionTask(with: request) { (result, error) in
                guard let result = result else {
                    let errorMessage = error?.localizedDescription ?? "Unknown error"
                    print("[AppleSpeechRecognizer] Recognition failed with error: \(errorMessage)")
                    continuation.resume(returning: nil)
                    return
                }

                if result.isFinal {
                    let transcription = result.bestTranscription.formattedString
                    print("[AppleSpeechRecognizer] Transcription successful: \(transcription)")
                    continuation.resume(returning: transcription)
                }
            }
        }
    }

    private func requestAuthorization() async {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authStatus in
                continuation.resume()
            }
        }
    }
} 