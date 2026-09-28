import Foundation

@main
struct AudioPipelineSmoke {
    static func main() {
        let original = Data((0..<123_456).map { UInt8($0 % 251) })
        for inputSize in [4, 1_364, 4_096, 6_400, 25_600] {
            var packets = AudioPacketBuffer()
            var received = Data()
            for offset in stride(from: 0, to: original.count, by: inputSize) {
                for packet in packets.append(original.subdata(in: offset..<min(offset + inputSize, original.count))) {
                    precondition(packet.count == 6_400)
                    received.append(packet)
                }
            }
            if let tail = packets.finish() { received.append(tail) }
            precondition(received == original, "合包或尾包丢失/重复了采样")
            precondition(packets.finish() == nil, "尾包不应重复发送")
        }
        var backlog = SendBacklog()
        let first = UUID(), second = UUID()
        precondition(backlog.insert(first, bytes: 200_000, at: 10))
        precondition(!backlog.insert(UUID(), bytes: 60_000, at: 10))
        precondition(backlog.bytes == 200_000)
        precondition(!backlog.isExpired(at: 14.9))
        precondition(backlog.isExpired(at: 15))
        precondition(!backlog.insert(UUID(), bytes: 1, at: 15))
        backlog.complete(first)
        precondition(backlog.isEmpty && backlog.bytes == 0)
        precondition(backlog.insert(second, bytes: 100, at: 16))
        backlog.complete(first) // A late completion must not release another send's budget.
        precondition(backlog.bytes == 100)
        backlog.complete(second)
        precondition(backlog.isEmpty)
        print("PASS: PCM 合包逐字节保持一致，尾包只发送一次；发送积压上限、超时和迟到回调正确")
    }
}
