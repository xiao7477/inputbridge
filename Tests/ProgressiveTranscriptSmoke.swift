import Foundation

@main
struct ProgressiveTranscriptSmoke {
    static func main() {
        var transcript = ProgressiveTranscript()
        precondition(transcript.apply("今天去", isFinal: false) == "今天去")
        precondition(transcript.apply("今天去公园", isFinal: false) == "今天去公园")
        precondition(transcript.apply("今天去公园", isFinal: true) == "今天去公园")
        precondition(transcript.apply("然后散", isFinal: false) == "今天去公园然后散")
        precondition(transcript.apply("", isFinal: false) == "今天去公园")
        precondition(transcript.apply("然后回家", isFinal: true) == "今天去公园然后回家")

        transcript.reset()
        precondition(transcript.apply("hello", isFinal: true) == "hello")
        precondition(transcript.apply("world", isFinal: false) == "hello world")
        precondition(transcript.finalized == "hello")
        print("PASS: 已确认前文保持不变，只修订当前临时尾句")
    }
}
