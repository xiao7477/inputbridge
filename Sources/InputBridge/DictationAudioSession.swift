import Foundation

@MainActor
protocol DictationAudioCapture: AnyObject {
    var onPacket: ((Data) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var latency: SpeechLatency? { get set }
    var canStartSpeculatively: Bool { get }
    func start(microphoneUID: String) async throws
    func stopMicrophone()
    func stop() async
    func cancel() async
}

/// Owns only one physical key gesture. Speculation never submits audio to an
/// engine or remote peer, and cancellation cannot stop a subsequent session.
@MainActor
final class DictationAudioSession {
    let id = UUID()
    let latency: SpeechLatency
    private let capture: DictationAudioCapture
    private let microphoneUID: String
    private var startup = StartupAudioBuffer()
    private var startTask: Task<Void, Error>?
    private var consumer: ((Data) throws -> Void)?
    private var failure: Error?
    private var cancelled = false
    private var microphoneStopped = false
    var onError: ((Error) -> Void)?
    var isConfirmed: Bool { startup.confirmed }

    init(microphoneUID: String, latency: SpeechLatency,
         capture suppliedCapture: DictationAudioCapture? = nil) {
        let capture = suppliedCapture ?? RemoteAudioCapture()
        self.latency = latency
        self.capture = capture
        self.microphoneUID = microphoneUID
        capture.latency = latency
        capture.onPacket = { [weak self] in self?.accept($0) }
        capture.onError = { [weak self] in self?.failed($0) }
        // An ordinary modifier chord must never open a first-use permission
        // dialog. Pre-roll starts immediately only with an existing grant.
        if capture.canStartSpeculatively { startCapture() }
    }

    func confirm() {
        startup.confirm()
        latency.mark("PTT confirmed")
        if startTask == nil, !cancelled, !microphoneStopped { startCapture() }
    }

    private func startCapture() {
        startTask = Task { [capture, microphoneUID] in
            try Task.checkCancellation()
            try await capture.start(microphoneUID: microphoneUID)
        }
    }

    func connect(_ consumer: @escaping (Data) throws -> Void) async throws {
        try await startTask?.value
        try Task.checkCancellation()
        if let failure { throw failure }
        guard !cancelled else { throw CancellationError() }
        // Yield between packets so a remote connection can complete sends.
        // Live packets stay queued until the entire prefix has been submitted.
        while !startup.packets.isEmpty {
            for packet in startup.drain() {
                try Task.checkCancellation()
                if let failure { throw failure }
                guard !cancelled else { throw CancellationError() }
                try consumer(packet)
                await Task.yield()
            }
        }
        self.consumer = consumer
    }

    /// Synchronous so releasing a key closes the microphone even if model
    /// preparation is still suspended. The converter can drain the captured tail.
    func stopMicrophone() {
        microphoneStopped = true
        startTask?.cancel()
        capture.stopMicrophone()
    }

    func stop() async {
        stopMicrophone()
        _ = await startTask?.result
        await capture.stop()
        startTask = nil
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        microphoneStopped = true
        consumer = nil
        _ = startup.drain()
        startTask?.cancel()
        let pending = startTask
        startTask = nil
        Task { [capture] in
            capture.stopMicrophone()
            _ = await pending?.result
            await capture.cancel()
        }
    }

    private func accept(_ data: Data) {
        guard !cancelled, failure == nil else { return }
        if let consumer {
            do { try consumer(data) }
            catch { failed(error) }
        }
        else if !startup.append(data) {
            failed(BridgeError.transport("语音启动超过音频缓存上限，已停止录音。请等待模型就绪后重试。"))
        }
    }

    private func failed(_ error: Error) {
        guard failure == nil, !cancelled else { return }
        failure = error
        capture.stopMicrophone()
        if isConfirmed { onError?(error) }
    }
}
