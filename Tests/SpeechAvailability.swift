import Foundation
import Speech

@main
struct SpeechAvailability {
    static func main() {
        for language in ["zh-CN", "en-US"] {
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language))
            print("\(language): exists=\(recognizer != nil), available=\(recognizer?.isAvailable ?? false), on-device=\(recognizer?.supportsOnDeviceRecognition ?? false)")
        }
    }
}
