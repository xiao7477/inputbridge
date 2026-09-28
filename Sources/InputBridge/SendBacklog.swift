import Foundation

/// Bound application-owned TCP sends. Completion means handed to the network
/// stack, not received by B; session progress is checked separately.
struct SendBacklog {
    static let byteLimit = 256_000
    static let timeout: TimeInterval = 5
    private var pending: [UUID: (bytes: Int, started: TimeInterval)] = [:]
    private(set) var bytes = 0

    var isEmpty: Bool { pending.isEmpty }

    func isExpired(at now: TimeInterval) -> Bool {
        pending.values.contains { now - $0.started >= Self.timeout }
    }

    mutating func insert(_ id: UUID, bytes count: Int, at now: TimeInterval) -> Bool {
        guard count <= Self.byteLimit - bytes, !isExpired(at: now) else { return false }
        pending[id] = (count, now)
        bytes += count
        return true
    }

    mutating func complete(_ id: UUID) {
        if let item = pending.removeValue(forKey: id) { bytes -= item.bytes }
    }
}
