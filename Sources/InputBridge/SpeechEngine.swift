import AVFoundation
import Speech

@MainActor
protocol SpeechEngine: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    func preparePermissions(locale: Locale) async throws
    func start(locale: Locale, microphoneUID: String) async throws
    func startNetwork(locale: Locale) async throws
    func appendNetworkAudio(_ data: Data)
    func stop() async
}

@MainActor
final class AppleSpeechEngine: SpeechEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var didFinish = false
    private var stopping = false

    func preparePermissions(locale: Locale) async throws {
        try await prepare(locale: locale, needsMicrophone: true)
    }

    func start(locale: Locale, microphoneUID: String) async throws {
        await cleanUp()
        try await prepare(locale: locale, needsMicrophone: true)
        try configureRecognition(locale: locale)

        let engine = AVAudioEngine()
        try AudioInputDeviceManager.configure(engine, deviceUID: microphoneUID)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let request else { throw BridgeError.transport("语音识别尚未准备好。") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            audioEngine = engine
        } catch {
            input.removeTap(onBus: 0)
            await cleanUp()
            throw error
        }
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

    func stop() async {
        guard request != nil || audioEngine != nil else { return }
        stopping = true
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        if !didFinish {
            await withCheckedContinuation { continuation in
                finishContinuation = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self?.finish()
                }
            }
        }
        await cleanUp()
    }

    private func prepare(locale: Locale, needsMicrophone: Bool) async throws {
        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard authorized else {
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
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.supportsOnDeviceRecognition else {
            throw BridgeError.unsupportedLocale
        }
        onStatus?("Apple 设备端听写模型已就绪")
    }

    private func configureRecognition(locale: Locale) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.supportsOnDeviceRecognition else {
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
        task = recognizer.recognitionTask(with: speechRequest) { [weak self] result, error in
            Task { @MainActor in self?.handle(result: result, error: error) }
        }
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
        if let audioEngine, audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        task = nil
        request = nil
        audioEngine = nil
        finish()
    }
}

@MainActor
func makeAppleSpeechEngine() -> SpeechEngine {
    if #available(macOS 26.0, *) { ModernAppleSpeechEngine() }
    else { AppleSpeechEngine() }
}
