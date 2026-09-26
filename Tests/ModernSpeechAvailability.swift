import Foundation
import Speech

@main
struct ModernSpeechAvailability {
    static func main() async {
        guard #available(macOS 26, *) else { return }
        let dictationLocales = await DictationTranscriber.supportedLocales
        let speechLocales = await SpeechTranscriber.supportedLocales
        print("dictation locales: \(dictationLocales.count), speech locales: \(speechLocales.count)")
        for language in ["zh-CN", "en-US"] {
            let locale = Locale(identifier: language)
            let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale)
            if let supported {
                let transcriber = DictationTranscriber(locale: supported, preset: .progressiveShortDictation)
                let status = await AssetInventory.status(forModules: [transcriber])
                let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])
                print("\(language): supported=\(supported.identifier), asset=\(status), install-request=\(request != nil)")
            } else {
                print("\(language): unsupported")
            }
        }
    }
}
