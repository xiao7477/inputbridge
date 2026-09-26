import AVFoundation
import Foundation

@main
struct NetworkAudioPCMSmoke {
    static func main() {
        let format = NetworkAudioPCM.format
        precondition(format.sampleRate == 16_000)
        precondition(format.channelCount == 1)
        guard let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320),
              let samples = source.floatChannelData?[0] else {
            fatalError("无法创建测试音频")
        }
        source.frameLength = 320
        for index in 0..<320 {
            samples[index] = Float(index) / 320
        }
        guard let data = NetworkAudioPCM.data(from: source),
              let restored = NetworkAudioPCM.makeBuffer(from: data),
              let restoredSamples = restored.floatChannelData?[0] else {
            fatalError("PCM 往返转换失败")
        }
        precondition(restored.frameLength == 320)
        precondition(restoredSamples[0] == 0)
        precondition(abs(restoredSamples[319] - samples[319]) < 0.000_001)
        print("PASS: 16 kHz 单声道网络 PCM 往返一致")
    }
}
