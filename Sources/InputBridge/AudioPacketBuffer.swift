import Foundation

/// 100 ms of 16 kHz mono Float32 PCM. Preserve every sample, including the stop tail.
struct AudioPacketBuffer {
    static let packetBytes = 6_400
    private var pending = Data()

    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var packets: [Data] = []
        while pending.count >= Self.packetBytes {
            packets.append(Data(pending.prefix(Self.packetBytes)))
            pending.removeFirst(Self.packetBytes)
        }
        return packets
    }

    mutating func finish() -> Data? {
        guard !pending.isEmpty else { return nil }
        let tail = pending
        pending = Data()
        return tail
    }
}
