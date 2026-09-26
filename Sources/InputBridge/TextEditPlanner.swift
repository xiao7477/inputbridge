import Foundation

struct TextEditPlan {
    let range: NSRange
    let replacement: String
    let valueAfterEdit: String
    let ownedRangeAfterEdit: NSRange
    let appendOnly: Bool
    let transcript: String
}

/// Tracks only the text produced by the current dictation session.
struct TextEditPlanner {
    private(set) var expectedValue: String
    private(set) var ownedRange: NSRange
    private(set) var transcript = ""
    private(set) var appendOnly = false

    init(value: String, selection: NSRange) {
        expectedValue = value
        ownedRange = selection
    }

    func plan(current: String, nextTranscript: String, selection: NSRange?) -> TextEditPlan {
        let currentLength = (current as NSString).length
        let editableRange = appendOnly ? nil : locateOwnedRange(in: current)
        let range: NSRange
        let replacement: String
        let nextAppendOnly: Bool

        if let editableRange {
            range = editableRange
            replacement = nextTranscript
            nextAppendOnly = false
        } else {
            let cursor = selection.map { min(max($0.location, 0), currentLength) } ?? currentLength
            range = NSRange(location: cursor, length: 0)
            replacement = String(nextTranscript.dropFirst(Self.commonPrefixLength(transcript, nextTranscript)))
            nextAppendOnly = true
        }

        let valueAfterEdit = (current as NSString).replacingCharacters(in: range, with: replacement)
        return TextEditPlan(
            range: range,
            replacement: replacement,
            valueAfterEdit: valueAfterEdit,
            ownedRangeAfterEdit: NSRange(location: range.location, length: (replacement as NSString).length),
            appendOnly: nextAppendOnly,
            transcript: nextTranscript
        )
    }

    mutating func commit(_ plan: TextEditPlan) {
        expectedValue = plan.valueAfterEdit
        ownedRange = plan.ownedRangeAfterEdit
        appendOnly = plan.appendOnly
        transcript = plan.transcript
    }

    private func locateOwnedRange(in current: String) -> NSRange? {
        let expected = expectedValue as NSString
        let actual = current as NSString
        guard NSMaxRange(ownedRange) <= expected.length else { return nil }
        if current == expectedValue { return ownedRange }

        if ownedRange.length > 0 {
            let ownedText = expected.substring(with: ownedRange)
            let first = actual.range(of: ownedText)
            if first.location != NSNotFound {
                let remaining = NSRange(location: NSMaxRange(first), length: actual.length - NSMaxRange(first))
                if actual.range(of: ownedText, options: [], range: remaining).location == NSNotFound {
                    return first
                }
            }
        }

        let oldUnits = Array(expectedValue.utf16)
        let newUnits = Array(current.utf16)
        let prefix = zip(oldUnits, newUnits).prefix { $0 == $1 }.count
        let suffix = zip(oldUnits.reversed(), newUnits.reversed())
            .prefix { $0 == $1 }.count
        let sharedSuffix = min(suffix, min(oldUnits.count - prefix, newUnits.count - prefix))
        let oldChangeEnd = oldUnits.count - sharedSuffix
        let delta = newUnits.count - oldUnits.count

        if oldChangeEnd <= ownedRange.location {
            return NSRange(location: ownedRange.location + delta, length: ownedRange.length)
        }
        if prefix >= NSMaxRange(ownedRange) { return ownedRange }
        if prefix >= ownedRange.location && oldChangeEnd <= NSMaxRange(ownedRange) {
            return NSRange(location: ownedRange.location, length: ownedRange.length + delta)
        }
        return nil
    }

    static func commonPrefixLength(_ first: String, _ second: String) -> Int {
        zip(first, second).prefix { $0 == $1 }.count
    }
}
