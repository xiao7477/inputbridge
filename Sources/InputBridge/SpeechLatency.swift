import Foundation
import os

/// Shared by the event tap, main actor, and audio callback. No audio or text is logged.
final class SpeechLatency: @unchecked Sendable {
    private let startedAt: TimeInterval
    private let id = String(UUID().uuidString.prefix(8))
    private let lock = NSLock()
    private var milestones = Set<String>()
    private static let logger = Logger(subsystem: "com.inputbridge.macos", category: "SpeechLatency")

    init(receivedAt: TimeInterval? = nil) {
        startedAt = receivedAt ?? ProcessInfo.processInfo.systemUptime
        mark("Hotkey received")
    }

    func mark(_ name: String) {
        #if DEBUG
        lock.lock()
        let first = milestones.insert(name).inserted
        lock.unlock()
        guard first else { return }
        let milliseconds = max(0, ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        Self.logger.debug("[SpeechLatency] \(self.id, privacy: .public) \(name, privacy: .public) +\(milliseconds, format: .fixed(precision: 1))ms")
        #endif
    }
}
