import Foundation

/// The unconfirmed modifier gesture retains at most 500 ms. Once confirmed,
/// preserve the beginning in order for up to 5 seconds of model/route startup.
/// Overflow is an error, never silent loss of the start of an utterance.
struct StartupAudioBuffer {
    private(set) var packets: [Data] = []
    private(set) var bytes = 0
    private(set) var confirmed = false
    static let speculativeLimit = 32_000 // 500 ms, 16 kHz Float32 mono
    static let startupLimit = 320_000 // 5 seconds

    mutating func confirm() { confirmed = true }

    mutating func append(_ data: Data) -> Bool {
        let limit = confirmed ? Self.startupLimit : Self.speculativeLimit
        if confirmed, bytes + data.count > limit { return false }
        packets.append(data)
        bytes += data.count
        while bytes > limit, let first = packets.first {
            bytes -= first.count
            packets.removeFirst()
        }
        return true
    }

    mutating func drain() -> [Data] {
        let result = packets
        packets.removeAll()
        bytes = 0
        return result
    }
}
