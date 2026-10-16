import Foundation

@MainActor
private final class FakeSpeechEngine: SpeechEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?
    var latency: SpeechLatency?
    var isPrepared = false
    var preparations = 0
    var cancellations = 0
    var retainsOnStop = false
    var failOnStart = false
    func preparePermissions(locale: Locale) async throws {}
    func startNetwork(locale: Locale) async throws {
        if failOnStart { throw BridgeError.unsupportedLocale }
        if !isPrepared { preparations += 1; isPrepared = true }
    }
    func appendNetworkAudio(_ data: Data) {}
    func stop(keepingResources: Bool) async {
        retainsOnStop = keepingResources
        isPrepared = keepingResources
    }
    func cancel() async { cancellations += 1; isPrepared = false }
}

private actor IdleDeadlines {
    private var waits: [CheckedContinuation<Void, Never>] = []
    private(set) var seconds: [Int] = []
    func wait(_ seconds: Int) async {
        self.seconds.append(seconds)
        await withCheckedContinuation { waits.append($0) }
    }
    func fire() {
        let pending = waits
        waits.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class FakeCapture: DictationAudioCapture {
    var onPacket: ((Data) -> Void)?
    var onError: ((Error) -> Void)?
    var latency: SpeechLatency?
    var running = false
    var canStartSpeculatively = true
    var minimumReadyAudioBytes = 1
    var starts = 0
    var cancelled = false
    var tail: Data?
    var delayStart = false
    var awaitingStart = false
    var resumeStart: CheckedContinuation<Void, Never>?
    func start(microphoneUID: String) async throws {
        starts += 1
        if delayStart {
            awaitingStart = true
            await withCheckedContinuation { resumeStart = $0 }
        }
        try Task.checkCancellation()
        running = true
    }
    func stopMicrophone() { running = false }
    func stop() async {
        running = false
        if let tail { onPacket?(tail); self.tail = nil }
    }
    func cancel() async { cancelled = true; running = false; tail = nil }
}

@main
struct SpeechStartupSmoke {
    @MainActor
    static func main() async throws {
        Task.detached {
            try? await Task.sleep(for: .seconds(20))
            fatalError("Speech startup smoke test exceeded 20 seconds")
        }
        FileHandle.standardError.write(Data("Testing speech lifecycle\n".utf8))
        try await lifecycle()
        FileHandle.standardError.write(Data("Testing audio sessions\n".utf8))
        try await captureReadiness()
        try await audioSession()
        bufferBounds()
        print("PASS: Cold/Warm lifecycle, first audio and Bluetooth readiness, cancellation/timeout, startup PCM order, stop tail, and speculative cancellation")
    }

    @MainActor
    private static func eventually(_ predicate: () async -> Bool) async {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        preconditionFailure("Timed out waiting for asynchronous cleanup")
    }

    @MainActor
    private static func lifecycle() async throws {
        let fake = FakeSpeechEngine()
        let clock = IdleDeadlines()
        let speech = RetainedSpeechEngine(engine: fake, idleWait: { await clock.wait($0) })
        let locale = Locale(identifier: "zh-CN")
        precondition(speech.state == .cold)
        try await speech.startNetwork(locale: locale)
        precondition(speech.state == .recording && fake.preparations == 1)
        await speech.stop()
        precondition(speech.state == .warm)
        await eventually { await clock.seconds.count == 1 }
        let firstDeadline = await clock.seconds
        precondition(firstDeadline == [300])

        try await speech.startNetwork(locale: locale)
        precondition(fake.preparations == 1, "Warm must reuse the prepared engine")
        await clock.fire() // A cancelled idle deadline must not release Recording.
        await Task.yield()
        precondition(speech.state == .recording && fake.cancellations == 0)
        await speech.stop()
        await eventually { await clock.seconds.count == 2 }
        await clock.fire()
        await eventually { speech.state == .cold && !fake.isPrepared }

        try await speech.startNetwork(locale: locale)
        precondition(fake.preparations == 2, "Expired Warm must rebuild once")
        speech.idleTimeout = .immediate
        await speech.stop()
        precondition(!fake.retainsOnStop && speech.state == .cold)

        speech.idleTimeout = .always
        try await speech.startNetwork(locale: locale)
        await speech.stop()
        precondition(speech.state == .warm && fake.isPrepared)
        speech.invalidate()
        await eventually { speech.state == .cold && !fake.isPrepared }

        try await speech.startNetwork(locale: locale)
        speech.invalidate() // Configuration change while recording is deferred.
        precondition(speech.state == .recording)
        await speech.stop()
        precondition(speech.state == .cold && !fake.retainsOnStop)

        fake.failOnStart = true
        do {
            try await speech.startNetwork(locale: locale)
            preconditionFailure("Expected start failure")
        } catch { precondition(speech.state == .cold && !fake.isPrepared) }
        fake.failOnStart = false
        try await speech.startNetwork(locale: locale)
        fake.onError?(BridgeError.unsupportedLocale)
        await speech.stop()
        precondition(speech.state == .cold && !fake.retainsOnStop)
    }

    @MainActor
    private static func captureReadiness() async throws {
        let capture = FakeCapture()
        let audio = DictationAudioSession(microphoneUID: "", latency: SpeechLatency(), capture: capture)
        audio.confirm()
        await eventually { capture.running }
        var connected = false
        var received = Data()
        let connection = Task { @MainActor in
            try await audio.connect { received.append($0) }
            connected = true
        }
        for _ in 0..<100 { await Task.yield() }
        precondition(!connected, "Microphone start is not audio readiness: wait for the first captured packet")
        capture.onPacket?(Data())
        for _ in 0..<100 { await Task.yield() }
        precondition(!connected, "An empty callback must not mark microphone audio ready")
        let opening = Data([1, 2, 3, 4])
        capture.onPacket?(opening)
        try await connection.value
        precondition(connected && received == opening, "The first packet must reach the engine before ready")
        await audio.stop()

        let bluetoothCapture = FakeCapture()
        bluetoothCapture.minimumReadyAudioBytes = 64_000
        let bluetooth = DictationAudioSession(microphoneUID: "", latency: SpeechLatency(), capture: bluetoothCapture)
        bluetooth.confirm()
        await eventually { bluetoothCapture.running }
        var bluetoothReady = false
        var bluetoothAudio = Data()
        let bluetoothConnection = Task { @MainActor in
            try await bluetooth.connect { bluetoothAudio.append($0) }
            bluetoothReady = true
        }
        let firstBluetoothPacket = Data(repeating: 1, count: 6_400)
        bluetoothCapture.onPacket?(firstBluetoothPacket)
        for _ in 0..<100 { await Task.yield() }
        precondition(!bluetoothReady, "The first Bluetooth packet must not bypass its startup window")
        let intermediateBluetoothAudio = Data(repeating: 2, count: 51_200)
        bluetoothCapture.onPacket?(intermediateBluetoothAudio)
        for _ in 0..<100 { await Task.yield() }
        precondition(!bluetoothReady, "0.9 seconds of Bluetooth audio must still be preparing")
        let finalBluetoothPacket = Data(repeating: 3, count: 6_400)
        bluetoothCapture.onPacket?(finalBluetoothPacket)
        try await bluetoothConnection.value
        precondition(bluetoothReady && bluetoothAudio == firstBluetoothPacket + intermediateBluetoothAudio + finalBluetoothPacket,
                     "Bluetooth startup audio must be retained in full, not discarded as warmup")
        await bluetooth.stop()

        let shortBluetoothCapture = FakeCapture()
        shortBluetoothCapture.minimumReadyAudioBytes = 64_000
        let shortBluetooth = DictationAudioSession(microphoneUID: "", latency: SpeechLatency(), capture: shortBluetoothCapture)
        shortBluetooth.confirm()
        await eventually { shortBluetoothCapture.running }
        shortBluetoothCapture.onPacket?(firstBluetoothPacket)
        shortBluetooth.stopMicrophone()
        var shortBluetoothAudio = Data()
        try await shortBluetooth.connect { shortBluetoothAudio.append($0) }
        await shortBluetooth.stop()
        precondition(shortBluetoothAudio == firstBluetoothPacket,
                     "Releasing during Bluetooth startup must still submit the captured short utterance")

        let releasedCapture = FakeCapture()
        let released = DictationAudioSession(microphoneUID: "", latency: SpeechLatency(), capture: releasedCapture)
        released.confirm()
        await eventually { releasedCapture.running }
        var releasedAudio = Data()
        let releasedConnection = Task { @MainActor in
            try await released.connect { releasedAudio.append($0) }
        }
        for _ in 0..<100 { await Task.yield() }
        releasedCapture.tail = opening
        released.stopMicrophone()
        try await releasedConnection.value
        await released.stop()
        precondition(releasedAudio == opening, "Release before the first packet must preserve the converter tail")

        let cancelledCapture = FakeCapture()
        let cancelled = DictationAudioSession(microphoneUID: "", latency: SpeechLatency(), capture: cancelledCapture)
        cancelled.confirm()
        await eventually { cancelledCapture.running }
        let cancelledConnection = Task { @MainActor in try await cancelled.connect { _ in } }
        for _ in 0..<100 { await Task.yield() }
        cancelled.cancel()
        do {
            try await cancelledConnection.value
            preconditionFailure("Cancelling before audio must unblock readiness with an error")
        } catch is CancellationError {}

        let silentCapture = FakeCapture()
        let silent = DictationAudioSession(microphoneUID: "", latency: SpeechLatency(), capture: silentCapture,
                                          firstAudioTimeout: .milliseconds(10))
        silent.confirm()
        do {
            try await silent.connect { _ in preconditionFailure("A stalled input must not submit audio") }
            preconditionFailure("A stalled microphone must fail instead of showing ready")
        } catch {
            precondition(!silentCapture.running)
        }
        silent.cancel()

        let failedCapture = FakeCapture()
        let failed = DictationAudioSession(microphoneUID: "", latency: SpeechLatency(), capture: failedCapture)
        failed.confirm()
        await eventually { failedCapture.running }
        let failedConnection = Task { @MainActor in try await failed.connect { _ in } }
        for _ in 0..<100 { await Task.yield() }
        failedCapture.onError?(BridgeError.transport("Input disconnected"))
        do {
            try await failedConnection.value
            preconditionFailure("An input failure must unblock readiness with its original error")
        } catch {
            precondition(error.localizedDescription == "Input disconnected" && !failedCapture.running)
        }
        failed.cancel()
    }

    @MainActor
    private static func audioSession() async throws {
        let capture = FakeCapture()
        let audio = DictationAudioSession(microphoneUID: "", latency: SpeechLatency(), capture: capture)
        await eventually { capture.running }
        let head = Data([1, 2, 3, 4]), live = Data([5, 6, 7, 8]), tail = Data([9, 10, 11, 12])
        capture.onPacket?(head)
        audio.confirm()
        capture.tail = tail
        audio.stopMicrophone() // Release while the recognizer is still preparing.
        precondition(!capture.running, "Releasing must synchronously close the microphone")
        var received = Data()
        try await audio.connect { received.append($0) }
        capture.onPacket?(live)
        await audio.stop()
        precondition(received == head + live + tail, "Pre-roll/live/tail must preserve every sample once")

        let speculativeCapture = FakeCapture()
        let speculative = DictationAudioSession(microphoneUID: "", latency: SpeechLatency(),
                                                capture: speculativeCapture)
        await eventually { speculativeCapture.running }
        speculativeCapture.onPacket?(head)
        speculative.cancel() // A normal modifier chord never submits its pre-roll.
        await eventually { speculativeCapture.cancelled }
        do {
            try await speculative.connect { _ in preconditionFailure("Cancelled audio escaped") }
            preconditionFailure("Cancelled speculation must not connect")
        } catch {}
        precondition(received == head + live + tail)

        let overloadedCapture = FakeCapture()
        let overloaded = DictationAudioSession(microphoneUID: "", latency: SpeechLatency(),
                                               capture: overloadedCapture)
        await eventually { overloadedCapture.running }
        overloaded.confirm()
        var failures = 0
        overloaded.onError = { _ in failures += 1 }
        overloadedCapture.onPacket?(Data(count: StartupAudioBuffer.startupLimit + 4))
        precondition(failures == 1 && !overloadedCapture.running)
        do {
            try await overloaded.connect { _ in preconditionFailure("Overflow must not submit truncated audio") }
            preconditionFailure("Expected overflow")
        } catch {}
        overloaded.cancel()

        let delayedCapture = FakeCapture()
        delayedCapture.delayStart = true
        let delayed = DictationAudioSession(microphoneUID: "", latency: SpeechLatency(),
                                            capture: delayedCapture)
        delayed.confirm()
        await eventually { delayedCapture.awaitingStart }
        delayed.stopMicrophone()
        delayedCapture.resumeStart?.resume()
        do {
            try await delayed.connect { _ in preconditionFailure("Released gesture started recording") }
            preconditionFailure("A release during permission wait must cancel microphone startup")
        } catch {}
        precondition(!delayedCapture.running)
        delayed.cancel()

        let orderingCapture = FakeCapture()
        let ordering = DictationAudioSession(microphoneUID: "", latency: SpeechLatency(),
                                             capture: orderingCapture)
        await eventually { orderingCapture.running }
        ordering.confirm()
        orderingCapture.onPacket?(head)
        orderingCapture.onPacket?(tail)
        var ordered = Data()
        try await ordering.connect { packet in
            ordered.append(packet)
            if ordered == head { orderingCapture.onPacket?(live) }
        }
        precondition(ordered == head + tail + live, "Live audio overtook the queued startup prefix")
        ordering.cancel()

        let firstUseCapture = FakeCapture()
        firstUseCapture.canStartSpeculatively = false
        let firstUse = DictationAudioSession(microphoneUID: "", latency: SpeechLatency(),
                                             capture: firstUseCapture)
        await Task.yield()
        precondition(firstUseCapture.starts == 0, "A normal chord must not request microphone permission")
        firstUse.cancel()
        precondition(firstUseCapture.starts == 0)
        let confirmedFirstUse = DictationAudioSession(microphoneUID: "", latency: SpeechLatency(),
                                                      capture: firstUseCapture)
        confirmedFirstUse.confirm()
        await eventually { firstUseCapture.running }
        firstUseCapture.onPacket?(head)
        try await confirmedFirstUse.connect { _ in }
        precondition(firstUseCapture.starts == 1)
        await confirmedFirstUse.stop()
    }

    private static func bufferBounds() {
        var buffer = StartupAudioBuffer()
        for value in 0..<10 {
            precondition(buffer.append(Data(repeating: UInt8(value), count: 6_400)))
            precondition(buffer.bytes <= StartupAudioBuffer.speculativeLimit)
        }
        precondition(buffer.packets.first?.first == 5)
        buffer.confirm()
        let opening = buffer.packets
        while buffer.bytes < StartupAudioBuffer.startupLimit {
            precondition(buffer.append(Data(repeating: 42, count: 6_400)))
        }
        precondition(!buffer.append(Data(count: 4)))
        precondition(Array(buffer.packets.prefix(opening.count)) == opening,
                     "Confirmed startup must preserve the opening instead of evicting it")
        let all = buffer.drain()
        precondition(all.reduce(0) { $0 + $1.count } == StartupAudioBuffer.startupLimit)
        precondition(buffer.bytes == 0 && buffer.drain().isEmpty)
    }
}
