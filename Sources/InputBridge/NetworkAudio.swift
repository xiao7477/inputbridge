import AVFoundation
import Foundation

enum NetworkAudioPCM {
    static let sampleRate = 16_000.0
    static let channelCount: AVAudioChannelCount = 1

    static var format: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
    }

    static func data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.channelCount == channelCount,
              let samples = buffer.floatChannelData?[0] else { return nil }
        return Data(bytes: samples,
                    count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
    }

    static func makeBuffer(from data: Data) -> AVAudioPCMBuffer? {
        guard !data.isEmpty,
              data.count.isMultiple(of: MemoryLayout<Float>.size) else { return nil }
        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Float>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            memcpy(samples, source, data.count)
        }
        return buffer
    }
}

@MainActor
final class RemoteAudioCapture {
    var onPacket: ((Data) -> Void)?
    var onError: ((Error) -> Void)?

    private struct SendableBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private final class CallbackBox: @unchecked Sendable {
        weak var owner: RemoteAudioCapture?

        init(owner: RemoteAudioCapture) {
            self.owner = owner
        }
    }

    private var audioEngine: AVAudioEngine?
    private var inputContinuation: AsyncStream<SendableBuffer>.Continuation?
    private var conversionTask: Task<Void, Never>?
    private var finishingTask: Task<Void, Never>?

    func start(microphoneUID: String) async throws {
        await stop()
        let allowed = await requestMicrophonePermission()
        guard allowed else {
            throw BridgeError.permission("请允许“语音输入共享”使用麦克风。")
        }

        let engine = AVAudioEngine()
        try AudioInputDeviceManager.configure(engine, deviceUID: microphoneUID)
        let inputNode = engine.inputNode
        let sourceFormat = inputNode.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw BridgeError.transport("无法取得麦克风音频格式。")
        }

        let (stream, continuation) = AsyncStream.makeStream(
            of: SendableBuffer.self,
            bufferingPolicy: .bufferingNewest(100)
        )
        inputContinuation = continuation
        let callbackBox = CallbackBox(owner: self)
        conversionTask = Task.detached(priority: .userInitiated) {
            let targetFormat = NetworkAudioPCM.format
            let converter = sourceFormat == targetFormat
                ? nil
                : AVAudioConverter(from: sourceFormat, to: targetFormat)

            for await payload in stream {
                let output: AVAudioPCMBuffer?
                if let converter {
                    let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
                    let capacity = AVAudioFrameCount(
                        ceil(Double(payload.buffer.frameLength) * ratio)
                    ) + 128
                    guard let converted = AVAudioPCMBuffer(
                        pcmFormat: targetFormat,
                        frameCapacity: capacity
                    ) else { continue }
                    var supplied = false
                    var conversionError: NSError?
                    let status = converter.convert(to: converted, error: &conversionError) {
                        _, inputStatus in
                        if supplied {
                            inputStatus.pointee = .noDataNow
                            return nil
                        }
                        supplied = true
                        inputStatus.pointee = .haveData
                        return payload.buffer
                    }
                    if status == .error {
                        if let conversionError {
                            await MainActor.run {
                                callbackBox.owner?.onError?(conversionError)
                            }
                        }
                        continue
                    }
                    output = converted.frameLength > 0 ? converted : nil
                } else {
                    output = payload.buffer
                }

                guard let output, let data = NetworkAudioPCM.data(from: output) else { continue }
                await MainActor.run { callbackBox.owner?.onPacket?(data) }
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) {
            buffer, _ in
            if let copy = Self.copyBuffer(buffer) {
                continuation.yield(SendableBuffer(buffer: copy))
            }
        }
        engine.prepare()
        do {
            try engine.start()
            audioEngine = engine
        } catch {
            inputNode.removeTap(onBus: 0)
            continuation.finish()
            await conversionTask?.value
            inputContinuation = nil
            conversionTask = nil
            throw error
        }
    }

    func stop() async {
        await finish(cancelPending: false)
    }

    func cancel() async {
        await finish(cancelPending: true)
    }

    private func finish(cancelPending: Bool) async {
        if let finishingTask {
            if cancelPending { conversionTask?.cancel() }
            await finishingTask.value
            return
        }
        let task = Task { @MainActor in
            if let audioEngine {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            inputContinuation?.finish()
            if cancelPending { conversionTask?.cancel() }
            await conversionTask?.value
            audioEngine = nil
            inputContinuation = nil
            conversionTask = nil
        }
        finishingTask = task
        await task.value
        finishingTask = nil
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        default:
            return false
        }
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
