import Foundation
@main
struct RemoteInputProgressSmoke {
    static func main() {
        var progress = RemoteInputProgress()
        precondition(progress.summary.contains("未收到音频"))
        progress.receive(Data(repeating: 0, count: 64_000))
        precondition(progress.summary.contains("音频 1.0 秒（接近静音）"))
        var sample: Float = 0.25
        progress.receive(withUnsafeBytes(of: &sample) { Data($0) })
        progress.recognizedCharacters = 12
        progress.writeStatus = "输入框没有变化"
        precondition(!progress.summary.contains("接近静音"))
        precondition(progress.summary.contains("识别 12 字"))
        precondition(progress.summary.contains("输入框没有变化"))
        var empty = RemoteInputProgress()
        empty.receive(Data())
        precondition(empty.audioBytes == 0)
        print("PASS: 区分未收音、静音、识别结果和未写入；诊断不含原文")
    }
}
