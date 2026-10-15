import AVFoundation
import Speech

@MainActor
protocol SpeechEngine: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    var latency: SpeechLatency? { get set }
    var isPrepared: Bool { get }
    func preparePermissions(locale: Locale) async throws
    func startNetwork(locale: Locale) async throws
    func appendNetworkAudio(_ data: Data)
    func stop(keepingResources: Bool) async
    func cancel() async
}

@MainActor
final class AppleSpeechEngine: SpeechEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?
    var latency: SpeechLatency?
    var isPrepared: Bool { recognizer != nil }

    private var recognizer: SFSpeechRecognizer?
    private var preparedLocale: String?
    private var sessionID = UUID()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var didFinish = false
    private var stopping = false

    func preparePermissions(locale: Locale) async throws {
        try await prepare(locale: locale, needsMicrophone: true)
    }

    func startNetwork(locale: Locale) async throws {
        await cleanUp()
        try await prepare(locale: locale, needsMicrophone: false)
        try configureRecognition(locale: locale)
    }

    func appendNetworkAudio(_ data: Data) {
        guard let buffer = NetworkAudioPCM.makeBuffer(from: data) else { return }
        request?.append(buffer)
    }

    func stop(keepingResources: Bool) async {
        guard request != nil else { return }
        stopping = true
        request?.endAudio()
        if !didFinish {
            let sessionID = sessionID
            await withCheckedContinuation { continuation in
                finishContinuation = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard self?.sessionID == sessionID else { return }
                    self?.finish()
                }
            }
        }
        await cleanUp()
        if !keepingResources {
            recognizer = nil
            preparedLocale = nil
        }
    }

    func cancel() async {
        stopping = true
        await cleanUp()
        recognizer = nil
        preparedLocale = nil
    }

    private func prepare(locale: Locale, needsMicrophone: Bool) async throws {
        var authorization = SFSpeechRecognizer.authorizationStatus()
        if authorization == .notDetermined {
            authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard authorization == .authorized else {
            throw BridgeError.permission("请允许“语音输入共享”使用语音识别。")
        }
        if needsMicrophone {
            let microphone = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
            guard microphone else {
                throw BridgeError.permission("请允许“语音输入共享”使用麦克风。")
            }
        }
        if preparedLocale != locale.identifier || recognizer == nil {
            guard let next = SFSpeechRecognizer(locale: locale),
                  next.supportsOnDeviceRecognition else { throw BridgeError.unsupportedLocale }
            recognizer = next
            preparedLocale = locale.identifier
        }
        onStatus?("Apple 设备端听写模型已就绪")
    }

    private func configureRecognition(locale: Locale) throws {
        guard let recognizer else {
            throw BridgeError.unsupportedLocale
        }
        guard recognizer.isAvailable else {
            throw BridgeError.transport("语音识别服务暂不可用。")
        }

        let speechRequest = SFSpeechAudioBufferRecognitionRequest()
        speechRequest.requiresOnDeviceRecognition = true
        speechRequest.shouldReportPartialResults = true
        speechRequest.taskHint = .dictation
        speechRequest.contextualStrings = TechnicalVocabulary.recognitionHints
        request = speechRequest
        didFinish = false
        stopping = false
        sessionID = UUID()
        let sessionID = sessionID
        task = recognizer.recognitionTask(with: speechRequest) { [weak self] result, error in
            Task { @MainActor in
                guard self?.sessionID == sessionID else { return }
                self?.handle(result: result, error: error)
            }
        }
        latency?.mark("Analyzer ready")
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = TechnicalVocabulary.correcting(result.bestTranscription.formattedString)
            if result.isFinal {
                onFinal?(text)
                finish()
            } else {
                onPartial?(text)
            }
        }
        if let error {
            if !stopping { onError?(error) }
            finish()
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func cleanUp() async {
        sessionID = UUID()
        task?.cancel()
        task = nil
        request = nil
        finish()
    }
}

@MainActor
func makeAppleSpeechEngine() -> SpeechEngine {
    if #available(macOS 26.0, *) { ModernAppleSpeechEngine() }
    else { AppleSpeechEngine() }
}
