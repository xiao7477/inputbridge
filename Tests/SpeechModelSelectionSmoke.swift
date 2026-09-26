import Foundation

@main
struct SpeechModelSelectionSmoke {
    static func main() {
        func choose(_ mode: ModelSelectionMode, _ a: RecognitionProvider,
                    aKey: Bool, _ b: RecognitionProvider, bKey: Bool) -> RecognitionProvider {
            SpeechModelSelection.decide(
                request: ModelRequest(mode: mode, preferred: a, controllerHasDoubaoKey: aKey),
                receiverPreferred: b, receiverHasDoubaoKey: bKey
            ).provider
        }
        precondition(choose(.automatic, .doubao, aKey: true, .apple, bKey: true) == .doubao)
        precondition(choose(.automatic, .doubao, aKey: true, .doubao, bKey: false) == .apple)
        precondition(choose(.automatic, .doubao, aKey: false, .doubao, bKey: true) == .apple)
        precondition(choose(.automatic, .apple, aKey: true, .doubao, bKey: true) == .apple)
        precondition(choose(.manual, .apple, aKey: false, .doubao, bKey: true) == .doubao)
        precondition(choose(.manual, .doubao, aKey: true, .apple, bKey: true) == .apple)
        precondition(choose(.manual, .doubao, aKey: true, .doubao, bKey: false) == .apple)
        print("PASS: 自动、手动与缺失密钥回退模型选择")
    }
}
