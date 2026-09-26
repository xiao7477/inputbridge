import Foundation

/// Only metadata is sent back to A; no transcript or field contents are logged.
struct RemoteInputProgress {
    var audioBytes = 0
    var peak: Float = 0
    var recognizedCharacters = 0
    var writtenCharacters = 0
    var target = "正在定位输入框"
    var writeStatus = "尚未写入"

    mutating func receive(_ audio: Data) {
        audioBytes += audio.count
        guard audio.count >= 4 else { return }
        audio.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: bytes.count - 3, by: 4) {
                let value = bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
                if value.isFinite { peak = max(peak, abs(value)) }
            }
        }
    }

    var summary: String {
        let seconds = Double(audioBytes) / 64_000
        let audio = audioBytes == 0 ? "未收到音频"
            : String(format: "音频 %.1f 秒%@", seconds, peak < 0.0001 ? "（接近静音）" : "")
        return "\(audio) · 识别 \(recognizedCharacters) 字 · \(writeStatus) · \(target)"
    }
}
