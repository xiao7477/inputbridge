import Foundation

@MainActor
final class DoubaoSpeechEngine: SpeechEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?

    private let apiKey: String
    private let resourceID: String
    private let capture = RemoteAudioCapture()
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var audioStream: AsyncStream<Data>.Continuation?
    private var sending: Task<Void, Never>?
    private var receiving: Task<Void, Never>?
    private var accumulatedPCM = Data()
    private var lastText = ""
    private var gotFinal = false
    private var stopping = false

    init(apiKey: String, resourceID: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.resourceID = resourceID
        capture.onPacket = { [weak self] bytes in self?.appendNetworkAudio(bytes) }
        capture.onError = { [weak self] error in self?.onError?(error) }
    }

    func preparePermissions(locale: Locale) async throws {
        guard !apiKey.isEmpty else {
            throw BridgeError.transport("尚未设置豆包语音 API Key。")
        }
    }

    func start(locale: Locale, microphoneUID: String) async throws {
        try await startNetwork(locale: locale)
        do { try await capture.start(microphoneUID: microphoneUID) }
        catch {
            await stop()
            throw error
        }
    }

    func startNetwork(locale: Locale) async throws {
        await cleanUp()
        try await preparePermissions(locale: locale)
        guard ["volc.seedasr.sauc.duration", "volc.seedasr.sauc.concurrent"].contains(resourceID) else {
            throw BridgeError.transport("请选择已开通的豆包语音 2.0 资源。")
        }
        var request = URLRequest(url: DoubaoASRProtocol.endpoint)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        socket.resume()
        let connectionTimeout = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        do {
            try await socket.send(.data(DoubaoASRProtocol.configuration()))
            let first = try await socket.receive()
            try Task.checkCancellation()
            guard self.socket === socket else { throw CancellationError() }
            connectionTimeout.cancel()
            let response = try Self.decode(first)
            if let error = response.error { throw BridgeError.transport(error) }
            gotFinal = response.isLast
            lastText = response.text.map(TechnicalVocabulary.correcting) ?? ""
            if !lastText.isEmpty { onPartial?(lastText) }
            let (stream, continuation) = AsyncStream.makeStream(
                of: Data.self, bufferingPolicy: .bufferingOldest(15)
            )
            audioStream = continuation
            sending = Task { [weak self] in
                guard let self else { return }
                do {
                    for await chunk in stream {
                        try Task.checkCancellation()
                        guard self.socket === socket else { return }
                        try await socket.send(.data(DoubaoASRProtocol.audio(chunk)))
                    }
                } catch {
                    if self.socket === socket, !self.stopping { self.onError?(error) }
                }
            }
            receiving = Task { [weak self] in
                guard let self else { return }
                do {
                    while !Task.isCancelled, !self.gotFinal {
                        let response = try Self.decode(try await socket.receive())
                        guard !Task.isCancelled, self.socket === socket else { return }
                        if let error = response.error {
                            throw BridgeError.transport(error)
                        }
                        if let value = response.text {
                            let corrected = TechnicalVocabulary.correcting(value)
                            if corrected != self.lastText {
                                self.lastText = corrected
                                self.onPartial?(corrected)
                            }
                        }
                        if response.isLast { self.gotFinal = true }
                    }
                } catch {
                    if self.socket === socket, !self.stopping { self.onError?(error) }
                }
            }
            onStatus?("豆包语音 2.0 已就绪")
        } catch {
            connectionTimeout.cancel()
            if self.socket === socket { await cleanUp() }
            throw error
        }
    }

    func appendNetworkAudio(_ data: Data) {
        guard let pcm = DoubaoASRProtocol.pcm16(fromFloat32: data), !pcm.isEmpty else { return }
        accumulatedPCM.append(pcm)
        while accumulatedPCM.count >= 6_400 {
            let chunk = Data(accumulatedPCM.prefix(6_400))
            accumulatedPCM.removeFirst(6_400)
            if case .dropped = audioStream?.yield(chunk) {
                onError?(BridgeError.transport("豆包连接发送过慢，音频缓冲已满。"))
            }
        }
    }

    func stop() async {
        guard let socket else { return }
        stopping = true
        // Cover draining queued sends as well as waiting for the final response.
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.onStatus?("豆包收尾超时，已停止等待")
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }
        await capture.stop()
        if !accumulatedPCM.isEmpty {
            let tail = accumulatedPCM
            accumulatedPCM.removeAll()
            _ = audioStream?.yield(tail)
        }
        audioStream?.finish()
        await sending?.value
        do { try await socket.send(.data(DoubaoASRProtocol.audio(Data(), last: true))) }
        catch { onStatus?("豆包音频结束包发送失败：\(error.localizedDescription)") }
        await receiving?.value
        timeout.cancel()
        if gotFinal { onFinal?(lastText) }
        await cleanUp()
    }

    func cancel() async {
        stopping = true
        socket?.cancel(with: .goingAway, reason: nil)
        audioStream?.finish()
        await capture.cancel()
        await cleanUp()
    }

    private static func decode(_ message: URLSessionWebSocketTask.Message) throws -> DoubaoASRResponse {
        switch message {
        case .data(let data): try DoubaoASRProtocol.decode(data)
        case .string: throw BridgeError.transport("豆包返回了非二进制识别响应。")
        @unknown default: throw BridgeError.transport("豆包返回了未知 WebSocket 响应。")
        }
    }

    private func cleanUp() async {
        audioStream?.finish()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        sending?.cancel()
        receiving?.cancel()
        socket = nil
        session = nil
        audioStream = nil
        sending = nil
        receiving = nil
        accumulatedPCM.removeAll()
        lastText = ""
        gotFinal = false
        stopping = false
    }
}
