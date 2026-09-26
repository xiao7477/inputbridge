import Foundation

struct ProgressiveTranscript {
    private(set) var finalized = ""
    private(set) var volatile = ""

    var text: String { Self.join(finalized, volatile) }

    @discardableResult
    mutating func apply(_ next: String, isFinal: Bool) -> String {
        if isFinal {
            volatile = ""
            finalized = Self.join(finalized, next)
        } else {
            volatile = next
        }
        return text
    }

    mutating func reset() {
        finalized = ""
        volatile = ""
    }

    private static func join(_ first: String, _ second: String) -> String {
        guard !first.isEmpty else { return second }
        guard !second.isEmpty else { return first }
        if let last = first.last, let next = second.first,
           last.isASCII, last.isLetter || last.isNumber,
           next.isASCII, next.isLetter || next.isNumber {
            return first + " " + second
        }
        return first + second
    }
}
