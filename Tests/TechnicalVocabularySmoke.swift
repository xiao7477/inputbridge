import Foundation

@main
struct TechnicalVocabularySmoke {
    static func main() {
        let input = "Cloude cloud Claude Caldece coldese Codex Swift UI Git Hub Chat GPT Tail Scale skill"
        let expected = "Claude Claude Claude Codex Codex Codex SwiftUI GitHub ChatGPT Tailscale skill"
        precondition(TechnicalVocabulary.correcting(input) == expected)
        precondition(TechnicalVocabulary.correcting("cloudy coldeseExtra") == "cloudy coldeseExtra")
        precondition(TechnicalVocabulary.recognitionHints.contains("Claude"))
        precondition(TechnicalVocabulary.recognitionHints.contains("Codex"))
        print("PASS: 技术关键词提示与常见误识别纠正")
    }
}
