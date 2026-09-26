import Foundation

enum TechnicalVocabulary {
    static let recognitionHints = [
        "Claude",
        "Codex",
        "skill",
        "SwiftUI",
        "GitHub",
        "ChatGPT",
        "Tailscale"
    ]

    private static let corrections: [([String], String)] = [
        (["Cloude", "cloud"], "Claude"),
        (["Caldece", "coldese"], "Codex"),
        (["Swift UI"], "SwiftUI"),
        (["Git Hub"], "GitHub"),
        (["Chat GPT"], "ChatGPT"),
        (["Tail Scale"], "Tailscale")
    ]

    static func correcting(_ text: String) -> String {
        var corrected = text
        for (variants, replacement) in corrections {
            let alternatives = variants
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "|")
            let pattern = "(?i)(?<![A-Za-z0-9])(?:\(alternatives))(?![A-Za-z0-9])"
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            corrected = expression.stringByReplacingMatches(
                in: corrected,
                range: NSRange(corrected.startIndex..., in: corrected),
                withTemplate: replacement
            )
        }
        return corrected
    }
}
