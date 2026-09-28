import Foundation

enum ScreenSharingState: Equatable {
    case unavailable(String)
    case connected(Set<String>)
}

@MainActor
final class ScreenSharingMonitor {
    enum Direction: Equatable { case incoming, outgoing }
    var onChange: ((ScreenSharingState) -> Void)?
    private var pollTask: Task<Void, Never>?
    private var direction: Direction = .incoming
    private var lastState: ScreenSharingState?
    // Both directions share one off-main system snapshot per polling round.
    private static let snapshots = ScreenSharingSnapshots()

    func start(direction: Direction) {
        stop()
        self.direction = direction
        lastState = nil
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let direction = self.direction
                let snapshot = await Self.snapshots.read()
                guard !Task.isCancelled else { return }
                let state = Self.state(snapshot, direction: direction)
                if state != self.lastState {
                    self.lastState = state
                    self.onChange?(state)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    nonisolated static func query(direction: Direction) -> ScreenSharingState {
        state(readSnapshot(), direction: direction)
    }

    nonisolated fileprivate static func state(_ snapshot: Result<String, Error>,
                                              direction: Direction) -> ScreenSharingState {
        switch snapshot {
        case .success(let text): return .connected(parseRemoteAddresses(text, direction: direction))
        case .failure: return .unavailable("无法读取系统屏幕共享连接。")
        }
    }

    nonisolated fileprivate static func readSnapshot() -> Result<String, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-anv", "-p", "tcp"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else {
                return .failure(NSError(domain: "InputBridge.ScreenSharing", code: Int(process.terminationStatus)))
            }
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func parseRemoteAddresses(_ netstat: String,
                                                 direction: Direction) -> Set<String> {
        var addresses = Set<String>()
        for line in netstat.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 6,
                  fields[0].hasPrefix("tcp"),
                  fields[5] == "ESTABLISHED",
                  (direction == .incoming ? fields[3] : fields[4]).hasSuffix(".5900") else { continue }
            let remote = fields[4]
            guard let portSeparator = remote.lastIndex(of: ".") else { continue }
            let address = String(remote[..<portSeparator])
            if address != "*", !address.isEmpty {
                addresses.insert(normalize(address))
            }
        }
        return addresses
    }

    nonisolated static func normalize(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let withoutZone = trimmed.split(separator: "%", maxSplits: 1).first.map(String.init) ?? trimmed
        if withoutZone.hasPrefix("::ffff:") { return String(withoutZone.dropFirst(7)) }
        return withoutZone.lowercased()
    }
}

private actor ScreenSharingSnapshots {
    private var pending: Task<Result<String, Error>, Never>?
    private var cached: Result<String, Error>?
    private var cachedAt: TimeInterval = 0

    func read() async -> Result<String, Error> {
        if let pending { return await pending.value }
        if let cached, ProcessInfo.processInfo.systemUptime - cachedAt < 1 {
            return cached
        }
        let task = Task.detached(priority: .utility) { ScreenSharingMonitor.readSnapshot() }
        pending = task
        let value = await task.value
        cached = value
        cachedAt = ProcessInfo.processInfo.systemUptime
        pending = nil
        return value
    }
}
