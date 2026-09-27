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

    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var rawInput: AsyncStream<SendableAudioBuffer>.Continuation?
    private var conversionTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var transcript = ProgressiveTranscript()
    private var stopping = false

    private enum SelectedTranscriber {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var modules: [any SpeechModule] {
            switch self {
            case .speech(let transcriber): [transcriber]
            case .dictation(let transcriber): [transcriber]
            }
        }

        var readyStatus: String {
            switch self {
            case .speech: "Apple 长音频转写模型已就绪"
            case .dictation: "Apple 设备端听写模型已就绪"
            }
        }
    }

    private struct SendableAudioBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    func preparePermissions(locale: Locale) async throws {
        _ = try await prepare(locale: locale, needsMicrophone: true)
    }

    func start(locale: Locale, microphoneUID: String) async throws {
        await cleanUp()
        let selected = try await prepare(locale: locale, needsMicrophone: true)
        let engine = AVAudioEngine()
        try AudioInputDeviceManager.configure(engine, deviceUID: microphoneUID)
        let inputNode = engine.inputNode
        let naturalFormat = inputNode.outputFormat(forBus: 0)
        try await startAnalyzer(selected: selected, inputFormat: naturalFormat)

        guard let rawInput else {
            await cleanUp()
            throw BridgeError.transport("语音识别音频通道尚未准备好。")
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: naturalFormat) {
            buffer, _ in
            if let copy = Self.copyBuffer(buffer) {
                rawInput.yield(SendableAudioBuffer(buffer: copy))
            }
        }
        engine.prepare()
        do {
            try engine.start()
            audioEngine = engine
        } catch {
            inputNode.removeTap(onBus: 0)
            await cleanUp()
            throw error
        }
    }

    func startNetwork(locale: Locale) async throws {
        await cleanUp()
        let selected = try await prepare(locale: locale, needsMicrophone: false)
        try await startAnalyzer(selected: selected, inputFormat: NetworkAudioPCM.format)
    }

    func appendNetworkAudio(_ data: Data) {
        guard let buffer = NetworkAudioPCM.makeBuffer(from: data) else { return }
        rawInput?.yield(SendableAudioBuffer(buffer: buffer))
    }

    func stop() async {
        guard analyzer != nil || audioEngine != nil else { return }
        stopping = true
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        rawInput?.finish()
        await conversionTask?.value
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                if !Task.isCancelled, !stopping { onError?(error) }
            }
        }
        await resultsTask?.value
        await cleanUp()
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
        return selected
    }

    private func startAnalyzer(selected: SelectedTranscriber,
                               inputFormat: AVAudioFormat) async throws {
        guard let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: selected.modules,
            considering: inputFormat
        ) else {
            throw BridgeError.transport("无法取得兼容的语音音频格式。")
        }

        let (rawStream, rawBuilder) = AsyncStream.makeStream(
            of: SendableAudioBuffer.self,
            bufferingPolicy: .bufferingNewest(150)
        )
        let (analysisStream, analysisBuilder) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(150)
        )
        rawInput = rawBuilder
        conversionTask = Task.detached(priority: .userInitiated) {
            let converter = inputFormat == analysisFormat
                ? nil
                : AVAudioConverter(from: inputFormat, to: analysisFormat)
            for await payload in rawStream {
                let buffer = payload.buffer
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
                    _ = converter.convert(to: output, error: &conversionError) {
                        _, status in
                        if supplied {
                            status.pointee = .noDataNow
                            return nil
                        }
                        supplied = true
                        status.pointee = .haveData
                        return payload.buffer
                    }
                    if output.frameLength > 0 {
                        analysisBuilder.yield(AnalyzerInput(buffer: output))
                    }
                } else {
                    analysisBuilder.yield(AnalyzerInput(buffer: buffer))
                }
            }
            analysisBuilder.finish()
        }

        let analyzer = SpeechAnalyzer(
            modules: selected.modules,
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        let context = AnalysisContext()
        context.contextualStrings[.general] = TechnicalVocabulary.recognitionHints
        try await analyzer.setContext(context)
        self.analyzer = analyzer
        transcript.reset()
        stopping = false
        startResultsTask(for: selected)

        do {
            try await analyzer.prepareToAnalyze(in: analysisFormat)
            try await analyzer.start(inputSequence: analysisStream)
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
        case .speech(let transcriber):
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.handle(text: String(result.text.characters),
                                     isFinal: result.isFinal)
                    }
                } catch {
                    if let self, !Task.isCancelled, !self.stopping {
                        self.onError?(error)
                    }
                }
            }
        case .dictation(let transcriber):
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
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
                return .speech(transcriber)
            }
        }
        guard let supported = await DictationTranscriber.supportedLocale(
            equivalentTo: locale
        ) else {
            throw BridgeError.unsupportedLocale
        }
        return .dictation(
            DictationTranscriber(locale: supported, preset: Self.dictationPreset)
        )
    }

    private static var dictationPreset: DictationTranscriber.Preset {
        var preset = DictationTranscriber.Preset.progressiveLongDictation
        preset.reportingOptions.insert(.frequentFinalization)
        return preset
    }

    private func cleanUp() async {
        if let audioEngine, audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        rawInput?.finish()
        conversionTask?.cancel()
        resultsTask?.cancel()
        if let analyzer { await analyzer.cancelAndFinishNow() }
        audioEngine = nil
        self.analyzer = nil
        rawInput = nil
        conversionTask = nil
        resultsTask = nil
        stopping = false
    }

    nonisolated private static func copyBuffer(
        _ source: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(from.count, to.count) {
            guard let sourceData = from[index].mData,
                  let targetData = to[index].mData else { continue }
            memcpy(targetData, sourceData, Int(from[index].mDataByteSize))
            to[index].mDataByteSize = from[index].mDataByteSize
        }
        return copy
    }
}
