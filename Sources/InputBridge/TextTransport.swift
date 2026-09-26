import Foundation
import Network

struct ConnectedPeer: Identifiable, Equatable {
    let id: UUID              // TCP connection ID
    let deviceID: UUID
    let name: String
    let address: String
}

@MainActor
final class TextTransportClient {
    private var connection: NWConnection?
    private var authenticated = false
    private let queue = DispatchQueue(label: "InputBridge.client")
    var onStatus: ((String) -> Void)?
    var onMessage: ((TextMessage) -> Void)?

    var isConnected: Bool { connection != nil && authenticated }

    func connect(host: String, port: UInt16, token: String,
                 deviceID: UUID, deviceName: String) async throws {
        disconnect()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw BridgeError.invalidPort }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        self.connection = connection
        authenticated = false
        onStatus?("连接中…")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate(continuation)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let hello = TextMessage(sessionId: UUID(), type: .hello, token: token,
                                            senderID: deviceID, senderName: deviceName)
                    guard let data = try? JSONEncoder().encode(hello) + Data([0x0A]) else {
                        gate.resume(.failure(BridgeError.transport("无法建立配对会话。")))
                        return
                    }
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error { gate.resume(.failure(error)) }
                    })
                    Self.receiveWelcome(on: connection, buffer: Data(), gate: gate)
                case .failed(let error):
                    gate.resume(.failure(error))
                    Task { @MainActor in
                        if self?.connection === connection {
                            self?.connection = nil
                            self?.authenticated = false
                            self?.onStatus?("连接失败：\(error.localizedDescription)")
                        }
                    }
                case .cancelled:
                    gate.resume(.failure(BridgeError.transport("连接已关闭。")))
                    Task { @MainActor in
                        if self?.connection === connection {
                            self?.connection = nil
                            self?.authenticated = false
                            self?.onStatus?("已断开")
                        }
                    }
                case .waiting:
                    Task { @MainActor in
                        if self?.connection === connection { self?.onStatus?("等待网络权限或连接…") }
                    }
                default: break
                }
            }
            connection.start(queue: queue)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                gate.resume(.failure(BridgeError.transport("连接超时，请检查网络和接收端设置。")))
                await MainActor.run {
                    if self?.connection === connection, self?.authenticated == false { self?.disconnect() }
                }
            }
        }
        authenticated = true
        Self.receiveMessages(on: connection, buffer: Data()) { [weak self] message in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                self.onMessage?(message)
            }
        }
        onStatus?("已配对连接")
    }

    nonisolated private static func receiveWelcome(on connection: NWConnection,
                                                    buffer: Data, gate: ContinuationGate) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
            var next = buffer
            if let data { next.append(data) }
            if let end = next.firstIndex(of: 0x0A) {
                let line = next.prefix(upTo: end)
                if let message = try? JSONDecoder().decode(TextMessage.self, from: line) {
                    if message.version == TextMessage.version, message.type == .welcome {
                        gate.resume(.success(()))
                        return
                    }
                    if message.type == .rejected {
                        gate.resume(.failure(BridgeError.transport(
                            message.reason ?? "被操作端拒绝了配对。"
                        )))
                        connection.cancel()
                        return
                    }
                }
                gate.resume(.failure(BridgeError.transport("对方 App 版本不兼容，请在两台 Mac 上安装同一版本。")))
                connection.cancel()
                return
            }
            if next.count > 65_536 || complete || error != nil {
                gate.resume(.failure(BridgeError.transport("对方没有完成配对，请确认两台 Mac 运行的是同一版本。")))
                connection.cancel()
                return
            }
            receiveWelcome(on: connection, buffer: next, gate: gate)
        }
    }

    func send(_ message: TextMessage) throws {
        guard let connection, authenticated else { throw BridgeError.noConnection }
        let data = try JSONEncoder().encode(message) + Data([0x0A])
        guard data.count <= 65_536 else { throw BridgeError.transport("单条消息过长。") }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                Task { @MainActor in self?.onStatus?("发送失败：\(error.localizedDescription)") }
            }
        })
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        authenticated = false
        onStatus?("未连接")
    }

    nonisolated private static func receiveMessages(
        on connection: NWConnection,
        buffer: Data,
        handler: @escaping @Sendable (TextMessage) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            data, _, complete, error in
            var next = buffer
            if let data { next.append(data) }
            while let end = next.firstIndex(of: 0x0A) {
                let line = next.prefix(upTo: end)
                next.removeSubrange(...end)
                guard let message = try? JSONDecoder().decode(TextMessage.self, from: line),
                      message.version == TextMessage.version else {
                    connection.cancel()
                    return
                }
                handler(message)
            }
            if next.count > 65_536 || complete || error != nil {
                connection.cancel()
                return
            }
            receiveMessages(on: connection, buffer: next, handler: handler)
        }
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

@MainActor
final class TextTransportServer {
    private var listener: NWListener?
    private var generation = 0
    private var connections: [UUID: NWConnection] = [:]
    private(set) var peers: [UUID: ConnectedPeer] = [:]
    private let queue = DispatchQueue(label: "InputBridge.server")
    var onMessage: ((TextMessage, UUID) -> Void)?
    var onPeersChanged: (([ConnectedPeer]) -> Void)?
    var onStatus: ((String) -> Void)?
    var pairingAuthorization: ((_ deviceID: UUID, _ name: String, _ address: String) -> String?)?

    func start(port: UInt16, token: String) throws {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw BridgeError.invalidPort }
        generation += 1
        let currentGeneration = generation
        let listener = try NWListener(using: .tcp, on: endpointPort)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard self?.generation == currentGeneration else { return }
                switch state {
                case .ready: self?.onStatus?("正在监听端口 \(port)")
                case .failed(let error): self?.onStatus?("监听失败：\(error.localizedDescription)")
                case .waiting: self?.onStatus?("等待本地网络权限…")
                case .cancelled: self?.onStatus?("接收已关闭")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                if self?.generation == currentGeneration { self?.accept(connection) }
                else { connection.cancel() }
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        generation += 1
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        peers.removeAll()
        onPeersChanged?([])
        onStatus?("接收已关闭")
    }

    func send(_ message: TextMessage, to connectionID: UUID) throws {
        guard let connection = connections[connectionID], peers[connectionID] != nil else {
            throw BridgeError.noConnection
        }
        let data = try JSONEncoder().encode(message) + Data([0x0A])
        guard data.count <= 65_536 else {
            throw BridgeError.transport("单条消息过长。")
        }
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil { connection.cancel() }
        })
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.remove(id) } }
            if case .cancelled = state { Task { @MainActor in self?.remove(id) } }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id, buffer: Data())
    }

    private func remove(_ id: UUID) {
        connections.removeValue(forKey: id)
        if peers.removeValue(forKey: id) != nil { onPeersChanged?(Array(peers.values)) }
    }

    private func receive(on connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            var next = buffer
            if let data { next.append(data) }
            var messages: [TextMessage] = []
            while let end = next.firstIndex(of: 0x0A) {
                let line = next.prefix(upTo: end)
                next.removeSubrange(...end)
                guard let message = try? JSONDecoder().decode(TextMessage.self, from: line) else {
                    connection.cancel()
                    return
                }
                messages.append(message)
            }
            if next.count > 65_536 {
                connection.cancel()
                return
            }
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                for message in messages { self.handle(message, on: connection, id: id) }
                if complete || error != nil { connection.cancel() }
                else { self.receive(on: connection, id: id, buffer: next) }
            }
        }
    }

    private func handle(_ message: TextMessage, on connection: NWConnection, id: UUID) {
        guard connections[id] === connection else {
            connection.cancel()
            return
        }
        guard message.version == TextMessage.version else {
            reject("两台 Mac 的 App 版本不同，请更新后重试。", message: message,
                   connection: connection)
            return
        }
        if message.type == .hello {
            guard peers[id] == nil else { connection.cancel(); return }
            let address: String
            if case .hostPort(let host, _) = connection.endpoint {
                address = ScreenSharingMonitor.normalize(String(describing: host))
            } else {
                address = ""
            }
            if let rejection = pairingAuthorization?(message.senderID, message.senderName, address) {
                reject(rejection, message: message, connection: connection)
                return
            }
            peers[id] = ConnectedPeer(id: id, deviceID: message.senderID,
                                      name: String(message.senderName.prefix(80)), address: address)
            onPeersChanged?(Array(peers.values))
            let welcome = TextMessage(sessionId: message.sessionId, type: .welcome, token: "",
                                      senderID: UUID(), senderName: "InputBridge")
            if let data = try? JSONEncoder().encode(welcome) + Data([0x0A]) {
                connection.send(content: data, completion: .contentProcessed { error in
                    if error != nil { connection.cancel() }
                })
            }
            return
        }
        guard let peer = peers[id], peer.deviceID == message.senderID,
              message.type != .welcome, message.type != .rejected else {
            connection.cancel()
            return
        }
        onMessage?(message, id)
    }

    private func reject(_ reason: String, message: TextMessage, connection: NWConnection) {
        let response = TextMessage(
            sessionId: message.sessionId,
            type: .rejected,
            token: "",
            senderID: UUID(),
            senderName: "语音输入共享",
            reason: reason
        )
        guard let data = try? JSONEncoder().encode(response) + Data([0x0A]) else {
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
