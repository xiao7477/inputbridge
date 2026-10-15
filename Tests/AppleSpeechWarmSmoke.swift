import Foundation
import Speech

/// Optional integration probe: uses synthetic silence and already-installed
/// assets only. Never opens the microphone or installs speech models.
@main
struct AppleSpeechWarmSmoke {
    @MainActor
    static func main() async throws {
        guard #available(macOS 26, *) else {
            print("SKIP: SpeechAnalyzer requires macOS 26")
            return
        }
        Task.detached {
            try? await Task.sleep(for: .seconds(30))
            fatalError("Apple speech integration probe exceeded 30 seconds")
        }
        var exercised = 0
        for language in ["zh-CN", "en-US"] {
            let locale = Locale(identifier: language)
            let modules: [any SpeechModule]
            if SpeechTranscriber.isAvailable,
               let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale),
               await AssetInventory.status(forModules: [
                SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
               ]) != .unsupported {
                modules = [SpeechTranscriber(locale: supported, preset: .progressiveTranscription)]
            } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                modules = [DictationTranscriber(locale: supported, preset: .progressiveLongDictation)]
            } else {
                print("SKIP: \(language) unavailable")
                continue
            }
            let status = await AssetInventory.status(forModules: modules)
            guard status == .installed else {
                print("SKIP: \(language) asset=\(status); probe will not download models")
                continue
            }
            let engine = RetainedSpeechEngine(engine: ModernAppleSpeechEngine())
            engine.idleTimeout = .always
            var errors: [Error] = []
            engine.onError = { errors.append($0) }
            for _ in 0..<2 {
                try await engine.startNetwork(locale: locale)
                for _ in 0..<5 { engine.appendNetworkAudio(Data(count: 6_400)) }
                await engine.stop()
                precondition(errors.isEmpty, "Apple engine returned \(errors)")
                precondition(engine.state == .warm, "Next analyzer was not prepared")
            }
            await engine.cancel()
            precondition(engine.state == .cold)
            exercised += 1
            print("PASS: \(language) two real Apple analyzer sessions and resource release")
        }
        if exercised == 0 { print("SKIP: no installed model available for real analyzer validation") }
    }
}
