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

    func start(direction: Direction) {
        stop()
        self.direction = direction
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let direction = self.direction
                let state = await Task.detached(priority: .utility) {
                    Self.query(direction: direction)
                }.value
                self.onChange?(state)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    nonisolated static func query(direction: Direction) -> ScreenSharingState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-anv", "-p", "tcp"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else {
                return .unavailable("无法读取系统屏幕共享连接。")
            }
            return .connected(parseRemoteAddresses(text, direction: direction))
        } catch {
            return .unavailable("无法检查屏幕共享连接：\(error.localizedDescription)")
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
