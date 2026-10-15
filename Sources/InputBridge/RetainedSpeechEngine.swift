import Foundation

enum SpeechResourceState: String { case cold = "Cold", warm = "Warm", recording = "Recording" }

enum SpeechIdleTimeout: Int, CaseIterable, Identifiable {
    case immediate = 0, oneMinute = 60, fiveMinutes = 300, tenMinutes = 600, always = -1
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .immediate: "立即释放"
        case .oneMinute: "1 分钟"
        case .fiveMinutes: "5 分钟"
        case .tenMinutes: "10 分钟"
        case .always: "始终保持就绪"
        }
    }
}

/// A single cancellable idle deadline; no polling, audio stream, or converter
/// runs while Warm. Each concrete engine owns its reusable in-memory resources.
@MainActor
final class RetainedSpeechEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?
    private(set) var state: SpeechResourceState = .cold
    private let engine: SpeechEngine
    private var idleTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var starting = false
    private var invalidated = false
    private var failed = false
    private let idleWait: @Sendable (Int) async throws -> Void
    var latency: SpeechLatency? {
        get { engine.latency }
        set { engine.latency = newValue }
    }
    var idleTimeout: SpeechIdleTimeout = .fiveMinutes {
        didSet { if state == .warm { scheduleRelease() } }
    }

    init(engine: SpeechEngine,
         idleWait: @escaping @Sendable (Int) async throws -> Void = {
             try await Task.sleep(for: .seconds($0))
         }) {
        self.engine = engine
        self.idleWait = idleWait
        engine.onPartial = { [weak self] in
            self?.latency?.mark("First partial transcript")
            self?.onPartial?($0)
        }
        engine.onFinal = { [weak self] in self?.onFinal?($0) }
        engine.onStatus = { [weak self] in self?.onStatus?($0) }
        engine.onError = { [weak self] error in
            self?.failed = true
            self?.onError?(error)
        }
    }

    func preparePermissions(locale: Locale) async throws {
        guard !starting, state != .recording else { return }
        idleTask?.cancel()
        idleTask = nil
        starting = true
        defer { starting = false }
        await releaseTask?.value
        releaseTask = nil
        do { try await engine.preparePermissions(locale: locale) }
        catch {
            await engine.cancel()
            state = .cold
            invalidated = false
            throw error
        }
        if invalidated {
            await engine.cancel()
            state = .cold
            invalidated = false
        } else if engine.isPrepared {
            state = .warm
            scheduleRelease()
        }
    }

    func startNetwork(locale: Locale) async throws {
        idleTask?.cancel()
        idleTask = nil
        starting = true
        failed = false
        defer { starting = false }
        await releaseTask?.value
        releaseTask = nil
        latency?.mark("Speech state: \(state.rawValue)")
        do {
            try await engine.startNetwork(locale: locale)
            state = .recording
            latency?.mark("Speech Engine ready")
        } catch {
            await engine.cancel()
            state = .cold
            invalidated = false
            throw error
        }
    }

    func appendNetworkAudio(_ data: Data) { engine.appendNetworkAudio(data) }

    func stop() async {
        await engine.stop(keepingResources: !invalidated && !failed && idleTimeout != .immediate)
        latency = nil
        if invalidated || failed || !engine.isPrepared {
            await engine.cancel()
            state = .cold
            invalidated = false
        } else {
            state = .warm
            scheduleRelease()
        }
    }

    func cancel() async {
        idleTask?.cancel()
        idleTask = nil
        await releaseTask?.value
        releaseTask = nil
        await engine.cancel()
        latency = nil
        state = .cold
        invalidated = false
    }

    func invalidate() {
        idleTask?.cancel()
        idleTask = nil
        if starting || state == .recording {
            invalidated = true
        } else {
            releaseIdleResources()
        }
    }

    private func scheduleRelease() {
        idleTask?.cancel()
        idleTask = nil
        guard idleTimeout != .always else { return }
        if idleTimeout == .immediate { releaseIdleResources(); return }
        let seconds = idleTimeout.rawValue
        idleTask = Task { [weak self, idleWait] in
            do { try await idleWait(seconds) }
            catch { return }
            guard !Task.isCancelled, let self, self.state == .warm, !self.starting else { return }
            self.releaseIdleResources()
        }
    }

    private func releaseIdleResources() {
        guard releaseTask == nil else { return }
        state = .cold
        releaseTask = Task { [engine] in await engine.cancel() }
    }

    deinit { idleTask?.cancel() }
}
