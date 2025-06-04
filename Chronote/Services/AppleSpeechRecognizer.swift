import Speech
import AVFoundation

@available(iOS 13.0, macOS 10.15, *)
class AppleSpeechRecognizer {

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    func transcribeAudio(fileURL: URL, localeIdentifier: String) async -> String? {
        // 检查并请求授权
        await requestAuthorization()

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            print("[AppleSpeechRecognizer] Speech recognition not authorized.")
            return nil
        }
        
        // 根据用户选择的语言初始化 SFSpeechRecognizer
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("[AppleSpeechRecognizer] Speech recognizer is not available for the selected locale or on this device.")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: fileURL)
            request.shouldReportPartialResults = false // 我们只需要最终结果

            recognizer.recognitionTask(with: request) { (result, error) in
                guard let result = result else {
                    let errorMessage = error?.localizedDescription ?? "Unknown error"
                    print("[AppleSpeechRecognizer] Recognition failed with error: \(errorMessage)")
                    continuation.resume(returning: nil)
                    return
                }

                if result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
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