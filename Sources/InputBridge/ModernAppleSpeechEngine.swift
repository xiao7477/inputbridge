import AVFoundation
import CoreMedia
import Speech

@available(macOS 26.0, *)
@MainActor
final class ModernAppleSpeechEngine: SpeechEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?
    var latency: SpeechLatency?
    var isPrepared: Bool { analyzer != nil }

    private var analyzer: SpeechAnalyzer?
    private var selected: SelectedTranscriber?
    private var preparedLocale: String?
    private var analysisFormat: AVAudioFormat?
    private var rawInput: AsyncStream<SendableAudioBuffer>.Continuation?
    private var conversionTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var transcript = ProgressiveTranscript()
    private var stopping = false

    private enum SelectedTranscriber {
        case speech(SpeechTranscriber, Locale)
        case dictation(DictationTranscriber, Locale)

        var modules: [any SpeechModule] {
            switch self {
            case .speech(let transcriber, _): [transcriber]
            case .dictation(let transcriber, _): [transcriber]
            }
        }

        var readyStatus: String {
            switch self {
            case .speech: "Apple 长音频转写模型已就绪"
            case .dictation: "Apple 设备端听写模型已就绪"
            }
        }

        /// Results streams belong to a single finished analysis session. Build
        /// fresh modules at stop, while the previous analyzer retains the model.
        @MainActor func fresh() -> SelectedTranscriber {
            switch self {
            case .speech(_, let locale):
                .speech(SpeechTranscriber(locale: locale,
                                          preset: .progressiveTranscription), locale)
            case .dictation(_, let locale):
                .dictation(DictationTranscriber(locale: locale,
                                                preset: ModernAppleSpeechEngine.dictationPreset), locale)
            }
        }
    }

    private struct SendableAudioBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private final class CallbackBox: @unchecked Sendable {
        weak var owner: ModernAppleSpeechEngine?
        init(_ owner: ModernAppleSpeechEngine) { self.owner = owner }
    }

    func preparePermissions(locale: Locale) async throws {
        _ = try await prepare(locale: locale, needsMicrophone: true)
    }

    func startNetwork(locale: Locale) async throws {
        do {
            if preparedLocale != locale.identifier || analyzer == nil {
                await cleanUp()
                let selected = try await prepare(locale: locale, needsMicrophone: false)
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: selected.modules, considering: NetworkAudioPCM.format
                ) else { throw BridgeError.transport("无法取得兼容的语音音频格式。") }
                self.selected = selected
                analysisFormat = format
                preparedLocale = locale.identifier
                latency?.mark("Analyzer preparation started")
                try await prepareAnalyzer(selected: selected, format: format)
                latency?.mark("Analyzer prepared")
            }
            try Task.checkCancellation()
            guard let selected, let analysisFormat else { throw CancellationError() }
            try await startAnalyzer(selected: selected, inputFormat: NetworkAudioPCM.format,
                                    analysisFormat: analysisFormat)
        } catch {
            await cleanUp()
            throw error
        }
    }

    func appendNetworkAudio(_ data: Data) {
        guard let buffer = NetworkAudioPCM.makeBuffer(from: data) else { return }
        if case .dropped = rawInput?.yield(SendableAudioBuffer(buffer: buffer)) {
            rawInput?.finish()
            onError?(BridgeError.transport("语音分析积压，听写已停止。请稍后重试。"))
        }
    }

    func stop(keepingResources: Bool) async {
        guard let analyzer, rawInput != nil else { return }
        stopping = true
        rawInput?.finish()
        await conversionTask?.value
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await cleanUp()
            onError?(error)
            return
        }
        await resultsTask?.value
        rawInput = nil
        conversionTask = nil
        resultsTask = nil
        guard keepingResources else { await cleanUp(); return }
        // No live stream, result listener, or converter survives into Warm.
        // Preparing the next isolated session here removes this work from the
        // next hotkey's critical path and keeps model ownership bounded.
        guard let selected, let analysisFormat else { await cleanUp(); return }
        let next = selected.fresh()
        self.selected = next
        do { try await prepareAnalyzer(selected: next, format: analysisFormat) }
        catch { await cleanUp() }
    }

    func cancel() async {
        stopping = true
        await cleanUp()
    }

    private func prepare(locale: Locale,
                         needsMicrophone: Bool) async throws -> SelectedTranscriber {
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
        let selected = try await selectTranscriber(locale: locale)
        let status = await AssetInventory.status(forModules: selected.modules)
        guard status != .unsupported else { throw BridgeError.unsupportedLocale }
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: selected.modules
        ) {
            onStatus?("正在下载 Apple 本地语音资源…")
            try await request.downloadAndInstall()
        }
        onStatus?(selected.readyStatus)
        latency?.mark("Speech assets ready")
        return selected
    }

    private func prepareAnalyzer(selected: SelectedTranscriber,
                                 format: AVAudioFormat) async throws {
        let analyzer = SpeechAnalyzer(
            modules: selected.modules,
            options: .init(priority: .userInitiated, modelRetention: .whileInUse)
        )
        let context = AnalysisContext()
        context.contextualStrings[.general] = TechnicalVocabulary.recognitionHints
        try await analyzer.setContext(context)
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
    }

    private func startAnalyzer(selected: SelectedTranscriber,
                               inputFormat: AVAudioFormat,
                               analysisFormat: AVAudioFormat) async throws {
        guard let analyzer else { throw CancellationError() }

        let (rawStream, rawBuilder) = AsyncStream.makeStream(
            of: SendableAudioBuffer.self,
            bufferingPolicy: .bufferingOldest(150)
        )
        let (analysisStream, analysisBuilder) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingOldest(150)
        )
        rawInput = rawBuilder
        let callbacks = CallbackBox(self)
        conversionTask = Task.detached(priority: .userInitiated) {
            defer { analysisBuilder.finish() }
            let converter = inputFormat == analysisFormat
                ? nil
                : AVAudioConverter(from: inputFormat, to: analysisFormat)
            for await payload in rawStream {
                guard !Task.isCancelled else { break }
                let buffer = payload.buffer
                let result: AVAudioPCMBuffer
                if let converter {
                    let ratio = analysisFormat.sampleRate / inputFormat.sampleRate
                    let capacity = AVAudioFrameCount(
                        ceil(Double(buffer.frameLength) * ratio)
                    ) + 128
                    guard let output = AVAudioPCMBuffer(
                        pcmFormat: analysisFormat,
                        frameCapacity: capacity
                    ) else { continue }
                    var supplied = false
                    var conversionError: NSError?
                    let status = converter.convert(to: output, error: &conversionError) {
                        _, status in
                        if supplied {
                            status.pointee = .noDataNow
                            return nil
                        }
                        supplied = true
                        status.pointee = .haveData
                        return payload.buffer
                    }
                    if status == .error {
                        rawBuilder.finish()
                        let error = conversionError ?? BridgeError.transport("语音音频转换失败。") as NSError
                        await MainActor.run {
                            callbacks.owner?.onError?(error)
                        }
                        break
                    }
                    guard output.frameLength > 0 else { continue }
                    result = output
                } else {
                    result = buffer
                }
                if case .dropped = analysisBuilder.yield(AnalyzerInput(buffer: result)) {
                    rawBuilder.finish()
                    await MainActor.run {
                        callbacks.owner?.onError?(BridgeError.transport("语音分析积压，听写已停止。请稍后重试。"))
                    }
                    break
                }
            }
        }

        transcript.reset()
        stopping = false
        startResultsTask(for: selected)

        do {
            try await analyzer.start(inputSequence: analysisStream)
            latency?.mark("Analyzer ready")
        } catch {
            rawBuilder.finish()
            await analyzer.cancelAndFinishNow()
            await cleanUp()
            throw error
        }
    }

    private func handle(text: String, isFinal: Bool) {
        let text = TechnicalVocabulary.correcting(text)
        if isFinal {
            onFinal?(transcript.apply(text, isFinal: true))
        } else {
            onPartial?(transcript.apply(text, isFinal: false))
        }
    }

    private func startResultsTask(for selected: SelectedTranscriber) {
        switch selected {
        case .speech(let transcriber, _):
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard !Task.isCancelled else { return }
                        self?.handle(text: String(result.text.characters),
                                     isFinal: result.isFinal)
                    }
                } catch {
                    if let self, !Task.isCancelled, !self.stopping {
                        self.onError?(error)
                    }
                }
            }
        case .dictation(let transcriber, _):
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard !Task.isCancelled else { return }
                        self?.handle(text: String(result.text.characters),
                                     isFinal: result.isFinal)
                    }
                } catch {
                    if let self, !Task.isCancelled, !self.stopping {
                        self.onError?(error)
                    }
                }
            }
        }
    }

    private func selectTranscriber(locale: Locale) async throws -> SelectedTranscriber {
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(
                locale: supported,
                preset: .progressiveTranscription
            )
            if await AssetInventory.status(forModules: [transcriber]) != .unsupported {
                return .speech(transcriber, supported)
            }
        }
        guard let supported = await DictationTranscriber.supportedLocale(
            equivalentTo: locale
        ) else {
            throw BridgeError.unsupportedLocale
        }
        return .dictation(
            DictationTranscriber(locale: supported, preset: Self.dictationPreset), supported
        )
    }

    private static var dictationPreset: DictationTranscriber.Preset {
        var preset = DictationTranscriber.Preset.progressiveLongDictation
        preset.reportingOptions.insert(.frequentFinalization)
        return preset
    }

    private func cleanUp() async {
        rawInput?.finish()
        conversionTask?.cancel()
        resultsTask?.cancel()
        if let analyzer { await analyzer.cancelAndFinishNow() }
        await conversionTask?.value
        await resultsTask?.value
        self.analyzer = nil
        selected = nil
        analysisFormat = nil
        preparedLocale = nil
        rawInput = nil
        conversionTask = nil
        resultsTask = nil
        stopping = false
    }

}
