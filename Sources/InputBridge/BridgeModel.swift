import AppKit
import Foundation
import ServiceManagement

@MainActor
final class BridgeModel: ObservableObject {
    let settings = AppSettings()
    @Published var connectionStatus = "未连接"
    @Published var receiverStatus = "接收已关闭"
    @Published var receiverInputModeStatus = "Apple Speech Framework（等待网络音频）"
    @Published var remoteProgressStatus = "尚未开始远程听写"
    @Published var remoteModelStatus = "未连接远程电脑"
    @Published var activeModelStatus = "Apple 本地识别"
    @Published var speechStatus = "就绪"
    @Published var errorMessage = ""
    @Published var isRecording = false
    @Published var isCapturingShortcut = false
    @Published var connectedPeers: [ConnectedPeer] = []
    @Published var activeControllerName = ""
    @Published private(set) var activeConnectionID: UUID?
    @Published private(set) var availableMicrophones: [AudioInputDevice] = []
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginStatus = "未启用"
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published var outgoingScreenSharingState: ScreenSharingState = .connected([])
    @Published var incomingScreenSharingState: ScreenSharingState = .connected([])
    @Published var automaticRouteStatus = "自动路由：本机输入"
    @Published var pairingStatus = "等待屏幕共享连接"
    @Published var isPairing = false

    private let client = TextTransportClient()
    private let server = TextTransportServer()
    private let outgoingScreenSharingMonitor = ScreenSharingMonitor()
    private let incomingScreenSharingMonitor = ScreenSharingMonitor()
    private let injector = TextInjector()
    private let overlay = VoiceOverlayController()
    private var speech: SpeechEngine = makeAppleSpeechEngine()
    private let remoteAudioCapture = RemoteAudioCapture()
    private let hotkey = GlobalHotkeyManager()
    private var outgoingSession: UUID?
    private var incomingSession: UUID?
    private var isStarting = false
    private var releaseRequested = false
    private var autoRouteTask: Task<Void, Never>?
    private var readySpeechStatus = "就绪"
    private var connectedTargetID: UUID?
    private var activeOutputRoute: OutputRoute?
    private var incomingStartTask: Task<Void, Never>?
    private var incomingAudioReady = false
    private var pendingIncomingAudio: [Data] = []
    private var pendingIncomingAudioBytes = 0
    private var isStoppingIncoming = false
    private var incomingTranscriptTask: Task<Void, Never>?
    private var pendingTranscript: String?
    private var incomingProgress = RemoteInputProgress()
    private var lastProgressSent = Date.distantPast
    private var remoteReadyContinuation: CheckedContinuation<Void, Error>?
    private var remoteReadyTimeout: Task<Void, Never>?
    private var remoteFinishTimeout: Task<Void, Never>?
    private var incomingFailed = false
    private var remoteCapability: ModelCapability?
    private let fallbackLoginAgentLabel = "com.inputbridge.macos.autostart"

    private enum OutputRoute {
        case local
        case remote(RemoteTarget)

        var isLocal: Bool {
            if case .local = self { return true }
            return false
        }

        var overlayStyle: VoiceOverlayStyle {
            isLocal ? .local : .remote
        }
    }

    init() {
        client.onStatus = { [weak self] status in
            guard let self else { return }
            self.connectionStatus = status
            if status == "已断开" || status == "未连接" || status.hasPrefix("连接失败") || status.hasPrefix("发送失败") {
                self.connectedTargetID = nil
                self.remoteCapability = nil
                self.remoteModelStatus = "未连接远程电脑"
                if self.activeOutputRoute?.isLocal == false {
                    self.remoteReadyContinuation?.resume(throwing: BridgeError.noConnection)
                    self.remoteReadyContinuation = nil
                    Task { @MainActor in
                        await self.remoteAudioCapture.stop()
                        self.clearOutgoingRemoteSession()
                        self.fail(BridgeError.transport("远程连接已断开，听写已停止。"))
                    }
                }
            }
        }
        client.onMessage = { [weak self] message in
            self?.receiveRemoteStatus(message)
        }
        server.onStatus = { [weak self] status in self?.receiverStatus = status }
        server.onMessage = { [weak self] message, connectionID in self?.receive(message, from: connectionID) }
        server.onPeersChanged = { [weak self] peers in self?.peersChanged(peers) }
        server.pairingAuthorization = { [weak self] deviceID, name, address in
            guard let self else { return "被操作端尚未准备好。" }
            return self.authorizePairing(deviceID: deviceID, name: name, address: address)
        }
        outgoingScreenSharingMonitor.onChange = { [weak self] state in
            self?.outgoingScreenSharingChanged(state)
        }
        incomingScreenSharingMonitor.onChange = { [weak self] state in
            self?.incomingScreenSharingChanged(state)
        }
        speech.onPartial = { [weak self] text in self?.deliverTranscript(text, final: false) }
        speech.onFinal = { [weak self] text in self?.deliverTranscript(text, final: true) }
        speech.onError = { [weak self] error in
            guard let self else { return }
            if self.incomingSession != nil {
                guard !self.isStoppingIncoming else { return }
                Task { @MainActor in
                    await self.failIncomingAudio(error)
                }
            } else {
                self.fail(error)
                Task { @MainActor in await self.endDictation() }
            }
        }
        speech.onStatus = { [weak self] status in
            self?.speechStatus = status
            if status.hasSuffix("已就绪") { self?.readySpeechStatus = status }
            if self?.incomingSession != nil {
                self?.receiverStatus = status
                self?.publishIncomingProgress(force: true)
            }
        }
        hotkey.onPress = { [weak self] in
            Task { @MainActor in await self?.beginDictation() }
        }
        hotkey.onRelease = { [weak self] in
            Task { @MainActor in await self?.endDictation() }
        }
        hotkey.onToggle = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.isRecording || self.isStarting { await self.endDictation() }
                else { await self.beginDictation() }
            }
        }
        hotkey.onCancel = { [weak self] in
            guard let self, self.isRecording || self.isStarting else { return false }
            Task { @MainActor in await self.endDictation() }
            return true
        }
        hotkey.onCapture = { [weak self] shortcut in
            self?.finishShortcutCapture(shortcut)
        }
        remoteAudioCapture.onPacket = { [weak self] data in
            guard let self,
                  let session = self.outgoingSession,
                  self.activeOutputRoute?.isLocal == false else { return }
            do {
                try self.client.send(
                    self.makeMessage(session: session, type: .audioChunk, audio: data)
                )
            } catch {
                self.fail(error)
                Task { @MainActor in await self.endDictation() }
            }
        }
        remoteAudioCapture.onError = { [weak self] error in
            guard let self else { return }
            self.fail(error)
            Task { @MainActor in await self.endDictation() }
        }
        if settings.token.isEmpty { settings.makeToken() }
        refreshMicrophones()
        refreshLaunchAtLoginStatus()
        hotkey.setActivationMode(settings.shortcutMode)
        do { try hotkey.register(settings.shortcut) }
        catch { fail(error) }
        startReceiver()
        outgoingScreenSharingMonitor.start(direction: .outgoing)
        incomingScreenSharingMonitor.start(direction: .incoming)
    }

    func setShortcut(_ shortcut: GlobalShortcut) {
        do {
            try hotkey.register(shortcut)
            settings.shortcut = shortcut
            errorMessage = ""
            if speechStatus == "需要处理" { speechStatus = readySpeechStatus }
        } catch { fail(error) }
    }

    func setShortcutMode(_ mode: ShortcutActivationMode) {
        hotkey.setActivationMode(mode)
        settings.shortcutMode = mode
    }

    func startShortcutCapture() {
        guard !isCapturingShortcut else { return }
        do {
            try hotkey.beginCapture()
            isCapturingShortcut = true
            errorMessage = ""
            if speechStatus == "需要处理" { speechStatus = readySpeechStatus }
        } catch { fail(error) }
    }

    func cancelShortcutCapture() {
        guard isCapturingShortcut else { return }
        hotkey.endCapture()
        isCapturingShortcut = false
    }

    private func finishShortcutCapture(_ shortcut: GlobalShortcut?) {
        guard isCapturingShortcut else { return }
        if let shortcut { setShortcut(shortcut) }
        hotkey.endCapture(suppressUntilRelease: shortcut?.keyCode != nil &&
            !(shortcut?.modifierKeyCodes.isEmpty ?? true))
        isCapturingShortcut = false
    }

    func refreshModelCapability() {
        let snapshot = ModelCapability(preferred: settings.recognitionProvider,
                                       hasDoubaoKey: settings.hasDoubaoKey,
                                       resourceID: settings.doubaoResourceID)
        if client.isConnected {
            try? client.send(makeMessage(session: UUID(), type: .modelProbe,
                                         modelCapability: snapshot))
        }
        for peer in connectedPeers {
            try? server.send(makeMessage(session: UUID(), type: .modelCapability,
                                         modelCapability: snapshot), to: peer.id)
        }
        updateRemoteModelStatus()
    }

    private func updateRemoteModelStatus() {
        guard client.isConnected else {
            remoteModelStatus = "未连接远程电脑"
            return
        }
        guard let remoteCapability else {
            remoteModelStatus = "等待远端模型配置"
            return
        }
        let request = ModelRequest(mode: settings.modelSelectionMode,
                                   preferred: settings.recognitionProvider,
                                   controllerHasDoubaoKey: settings.hasDoubaoKey)
        let decision = SpeechModelSelection.decide(
            request: request, receiverPreferred: remoteCapability.preferred,
            receiverHasDoubaoKey: remoteCapability.hasDoubaoKey
        )
        remoteModelStatus = decision.explanation
    }

    private func configureSpeech(_ provider: RecognitionProvider) {
        let next: SpeechEngine = provider == .doubao
            ? DoubaoSpeechEngine(apiKey: settings.doubaoAPIKey,
                                 resourceID: settings.doubaoResourceID)
            : makeAppleSpeechEngine()
        next.onPartial = speech.onPartial
        next.onFinal = speech.onFinal
        next.onError = speech.onError
        next.onStatus = speech.onStatus
        speech = next
        activeModelStatus = provider.title
    }

    func requestPermissions() async {
        TextInjector.requestPermission()
        do {
            try await speech.preparePermissions(locale: Locale(identifier: settings.locale))
            if TextInjector.hasPermission {
                try hotkey.register(settings.shortcut)
                errorMessage = ""
            } else {
                speechStatus = "此版本尚未获得辅助功能权限；若已勾选，请移除旧条目并重新添加当前 App，然后重启。"
            }
        } catch { fail(error) }
    }

    func refreshMicrophones() {
        availableMicrophones = AudioInputDeviceManager.availableDevices()
    }

    func refreshLaunchAtLoginStatus() {
        let fallbackEnabled = FileManager.default.fileExists(atPath: fallbackLoginAgentURL.path)
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginNeedsApproval = false
            launchAtLoginStatus = "已启用"
        case .requiresApproval:
            launchAtLoginEnabled = true
            launchAtLoginNeedsApproval = true
            launchAtLoginStatus = "等待系统允许"
        case .notRegistered:
            launchAtLoginEnabled = fallbackEnabled
            launchAtLoginNeedsApproval = false
            launchAtLoginStatus = fallbackEnabled ? "已启用" : "未启用"
        case .notFound:
            launchAtLoginEnabled = fallbackEnabled
            launchAtLoginNeedsApproval = false
            launchAtLoginStatus = fallbackEnabled ? "已启用" : "未启用"
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginNeedsApproval = false
            launchAtLoginStatus = "状态未知"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                let status = SMAppService.mainApp.status
                if status == .notRegistered || status == .notFound {
                    do {
                        try SMAppService.mainApp.register()
                    } catch {
                        try installFallbackLoginAgent()
                    }
                    if SMAppService.mainApp.status == .notRegistered ||
                        SMAppService.mainApp.status == .notFound {
                        try installFallbackLoginAgent()
                    }
                }
            } else {
                let status = SMAppService.mainApp.status
                if status == .enabled || status == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
                try removeFallbackLoginAgent()
            }
            refreshLaunchAtLoginStatus()
            errorMessage = ""
        } catch {
            refreshLaunchAtLoginStatus()
            errorMessage = "无法修改开机启动：\(error.localizedDescription)"
        }
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private var fallbackLoginAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(fallbackLoginAgentLabel).plist")
    }

    private func installFallbackLoginAgent() throws {
        guard let executablePath = Bundle.main.executableURL?.path else {
            throw BridgeError.transport("无法确定当前 App 的启动路径。")
        }
        let contents: [String: Any] = [
            "Label": fallbackLoginAgentLabel,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: contents,
            format: .xml,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: fallbackLoginAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fallbackLoginAgentURL, options: .atomic)
    }

    private func removeFallbackLoginAgent() throws {
        guard FileManager.default.fileExists(atPath: fallbackLoginAgentURL.path) else { return }
        try FileManager.default.removeItem(at: fallbackLoginAgentURL)
    }

    var selectedMicrophoneStatus: String {
        guard !settings.microphoneUID.isEmpty else { return "跟随系统" }
        return availableMicrophones.first { $0.uid == settings.microphoneUID }?.name
            ?? "所选设备不可用"
    }

    func connect() async {
        do {
            guard let target = settings.selectedTarget else {
                throw BridgeError.transport("请先添加一台目标 Mac。")
            }
            try await connect(to: target)
            errorMessage = ""
        } catch { fail(error) }
    }

    func pairCurrentScreenSharingTarget() async {
        guard !isPairing else { return }
        guard let address = outgoingScreenSharingAddress else {
            pairingStatus = "未检测到正在操作的远程 Mac"
            errorMessage = "请先打开 macOS 屏幕共享并连接目标 Mac。"
            return
        }

        isPairing = true
        pairingStatus = "正在连接 \(address)…"
        errorMessage = ""
        defer { isPairing = false }

        let target = settings.selectOrAddTarget(host: address)
        disconnect()
        do {
            try await connect(to: target)
            pairingStatus = "配对成功：\(target.name)"
            connectionStatus = "已准备远程输入：\(target.name)"
            errorMessage = ""
        } catch {
            pairingStatus = "配对失败：\(error.localizedDescription)"
            fail(error)
        }
    }

    func disconnect() {
        client.disconnect()
        connectedTargetID = nil
    }

    func restartNetworking() {
        disconnect()
        startReceiver()
        refreshAutomaticTarget()
    }

    func startReceiver() {
        do {
            guard let port = settings.listenPort else { throw BridgeError.invalidPort }
            try server.start(port: port, token: settings.token)
            errorMessage = ""
        } catch { fail(error) }
    }

    func beginDictation() async {
        guard !isRecording, !isStarting, incomingSession == nil, outgoingSession == nil else { return }
        if isPassiveReceiver {
            receiverStatus = "被操作端待命：等待操作端发送听写"
            return
        }
        isStarting = true
        releaseRequested = false
        defer { isStarting = false }
        do {
            let route = try await resolveOutputRoute()
            let session = UUID()
            outgoingSession = session
            activeOutputRoute = route
            switch route {
            case .local:
                let localProvider: RecognitionProvider = settings.recognitionProvider == .doubao &&
                    settings.hasDoubaoKey ? .doubao : .apple
                configureSpeech(localProvider)
                if settings.recognitionProvider == .doubao && !settings.hasDoubaoKey {
                    activeModelStatus = "Apple 本地识别（豆包未配置）"
                }
                try injector.begin()
                automaticRouteStatus = "正在输入到本机"
                overlay.show(label: "准备语音输入", style: route.overlayStyle)
                do {
                    try await speech.start(
                        locale: Locale(identifier: settings.locale),
                        microphoneUID: settings.microphoneUID
                    )
                } catch {
                    guard localProvider == .doubao else { throw error }
                    configureSpeech(.apple)
                    activeModelStatus = "Apple 本地识别（豆包启动失败）"
                    automaticRouteStatus = "豆包未就绪，本次使用 Apple 本地识别"
                    try await speech.start(
                        locale: Locale(identifier: settings.locale),
                        microphoneUID: settings.microphoneUID
                    )
                }
            case .remote(let target):
                automaticRouteStatus = "正在输入到 \(target.name)"
                remoteProgressStatus = "正在等待 B 定位输入框并启动识别"
                speechStatus = "等待 B 端准备…"
                overlay.show(label: "等待远端就绪", style: route.overlayStyle)
                try await prepareRemoteSession(session)
                if releaseRequested {
                    isRecording = true
                    await endDictation()
                    return
                }
                try await remoteAudioCapture.start(microphoneUID: settings.microphoneUID)
            }
            isRecording = true
            overlay.show(style: route.overlayStyle)
            speechStatus = route.isLocal
                ? "正在本机听写…"
                : "B 已就绪，正在发送音频…"
            errorMessage = ""
            if releaseRequested { await endDictation() }
        } catch {
            if activeOutputRoute?.isLocal == true { injector.end() }
            else if activeOutputRoute != nil, let outgoingSession {
                await remoteAudioCapture.stop()
                try? client.send(makeMessage(session: outgoingSession, type: .audioEnd))
            }
            remoteReadyTimeout?.cancel()
            outgoingSession = nil
            activeOutputRoute = nil
            overlay.hide()
            fail(error)
        }
    }

    func endDictation() async {
        if isStarting && !isRecording {
            releaseRequested = true
            return
        }
        guard isRecording else { return }
        isRecording = false
        speechStatus = "正在结束…"
        overlay.show(label: "正在完成", style: activeOutputRoute?.overlayStyle ?? .local)
        if activeOutputRoute?.isLocal == true {
            await speech.stop()
            injector.end()
        } else if activeOutputRoute != nil, let outgoingSession {
            await remoteAudioCapture.stop()
            guard self.outgoingSession == outgoingSession else { return }
            do {
                try client.send(makeMessage(session: outgoingSession, type: .audioEnd))
                speechStatus = "等待 B 完成识别和写入…"
                remoteFinishTimeout?.cancel()
                remoteFinishTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled, let self, self.outgoingSession == outgoingSession else { return }
                    self.clearOutgoingRemoteSession()
                    self.fail(BridgeError.transport("B 端结束超时，请查看远程链路状态。"))
                }
            } catch {
                clearOutgoingRemoteSession()
                fail(error)
            }
            return
        }
        outgoingSession = nil
        activeOutputRoute = nil
        overlay.hide()
        speechStatus = readySpeechStatus
        updateIdleRouteStatus()
    }

    private func deliverTranscript(_ text: String, final: Bool) {
        do {
            if incomingSession != nil, activeConnectionID != nil {
                guard !incomingFailed else { return }
                incomingProgress.recognizedCharacters = text.count
                pendingTranscript = text
                publishIncomingProgress(force: true)
                startIncomingTranscriptWriter()
            } else if outgoingSession != nil, activeOutputRoute?.isLocal == true {
                try injector.update(text)
            }
        } catch {
            if incomingSession != nil {
                Task { @MainActor in await failIncomingAudio(error) }
            } else {
                fail(error)
                Task { @MainActor in await endDictation() }
            }
        }
    }

    private func makeMessage(session: UUID, type: MessageKind,
                             text: String = "", audio: Data? = nil,
                             modelRequest: ModelRequest? = nil,
                             modelDecision: ModelDecision? = nil,
                             modelCapability: ModelCapability? = nil) -> TextMessage {
        TextMessage(sessionId: session, type: type, text: text, audio: audio,
                    token: settings.token,
                    senderID: settings.deviceID, senderName: settings.deviceName,
                    modelRequest: modelRequest, modelDecision: modelDecision,
                    modelCapability: modelCapability)
    }

    private func resolveOutputRoute() async throws -> OutputRoute {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        switch AutomaticRouteDecider.decide(frontmostBundleIdentifier: bundleID,
                                             outgoingScreenSharing: outgoingScreenSharingState) {
        case .local:
            return .local
        case .unavailable(let reason):
            throw BridgeError.transport(reason)
        case .remote(let address):
            guard let target = await matchingTarget(for: address) else {
                throw BridgeError.transport("屏幕共享目标 \(address) 尚未添加到远程电脑列表。")
            }
            settings.selectedTargetID = target.id
            if connectedTargetID != target.id || !client.isConnected {
                disconnect()
                try await connect(to: target)
            }
            guard client.isConnected else { throw BridgeError.noConnection }
            return .remote(target)
        }
    }

    private func connect(to target: RemoteTarget) async throws {
        guard let port = target.port else { throw BridgeError.invalidPort }
        let host = target.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw BridgeError.transport("请填写目标 Mac 的地址。") }
        try await client.connect(host: host, port: port, token: settings.token,
                                 deviceID: settings.deviceID, deviceName: settings.deviceName)
        connectedTargetID = target.id
        refreshModelCapability()
    }

    private func matchingTarget(for address: String) async -> RemoteTarget? {
        let targets = settings.targets
        return await Task.detached(priority: .utility) {
            targets.first { TargetResolver.addresses(for: $0.host).contains(address) }
        }.value
    }

    private func peersChanged(_ peers: [ConnectedPeer]) {
        connectedPeers = peers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let activeConnectionID, !peers.contains(where: { $0.id == activeConnectionID }) {
            Task { @MainActor in
                await abortIncomingAudio(status: "操控端已断开")
            }
        }
        if activeConnectionID == nil {
            updateReceiverStatusForScreenSharing()
        }
    }

    var outgoingScreenSharingAddress: String? {
        guard case .connected(let addresses) = outgoingScreenSharingState,
              addresses.count == 1 else { return nil }
        return addresses.first
    }

    var incomingScreenSharingAddress: String? {
        guard case .connected(let addresses) = incomingScreenSharingState,
              addresses.count == 1 else { return nil }
        return addresses.first
    }

    var isBeingScreenShared: Bool {
        if case .connected(let addresses) = incomingScreenSharingState {
            return !addresses.isEmpty
        }
        return false
    }

    var isPassiveReceiver: Bool {
        isBeingScreenShared && outgoingScreenSharingAddress == nil
    }

    private func updateHotkeyAvailability() {
        let shouldEnable = !isPassiveReceiver
        if !shouldEnable, isCapturingShortcut {
            isCapturingShortcut = false
        }
        hotkey.setEnabled(shouldEnable)
        if !shouldEnable, isRecording || isStarting {
            Task { @MainActor in await endDictation() }
        }
    }

    private func authorizePairing(deviceID: UUID, name: String, address: String) -> String? {
        if settings.isPairedController(deviceID) { return nil }
        guard let incomingAddress = incomingScreenSharingAddress else {
            return "被操作端没有检测到当前屏幕共享，请先连接屏幕共享。"
        }
        guard !address.isEmpty, address == incomingAddress else {
            return "配对请求不是来自当前屏幕共享的操作端。"
        }

        settings.rememberPairedController(deviceID)
        pairingStatus = "已接受 \(String(name.prefix(80))) 的配对"
        receiverStatus = "已配对 \(String(name.prefix(80)))，可接收听写"
        return nil
    }

    private func outgoingScreenSharingChanged(_ state: ScreenSharingState) {
        let previous = outgoingScreenSharingState
        outgoingScreenSharingState = state
        updateHotkeyAvailability()
        guard previous != state else { return }
        if let address = outgoingScreenSharingAddress {
            automaticRouteStatus = "检测到屏幕共享；切到共享窗口后自动远程输入"
            routeToScreenSharingTarget(address)
        } else {
            autoRouteTask?.cancel()
            autoRouteTask = nil
            if !isRecording {
                automaticRouteStatus = "自动路由：本机输入"
                disconnect()
            } else if activeOutputRoute?.isLocal == false {
                Task { @MainActor in await endDictation() }
            }
        }
    }

    private func incomingScreenSharingChanged(_ state: ScreenSharingState) {
        incomingScreenSharingState = state
        updateHotkeyAvailability()
        if let activeConnectionID,
           let peer = connectedPeers.first(where: { $0.id == activeConnectionID }),
           !isCurrentScreenSharingPeer(peer) {
            Task { @MainActor in
                await abortIncomingAudio(status: "屏幕共享来源已改变，远程听写已停止")
            }
        }
        guard activeConnectionID == nil else { return }
        updateReceiverStatusForScreenSharing()
    }

    private func updateReceiverStatusForScreenSharing() {
        guard activeConnectionID == nil else { return }
        switch incomingScreenSharingState {
        case .unavailable(let reason):
            receiverStatus = reason
            if outgoingScreenSharingAddress == nil {
                pairingStatus = "无法检测屏幕共享状态"
            }
        case .connected(let addresses) where addresses.isEmpty:
            receiverStatus = "未检测到屏幕共享连接"
            if outgoingScreenSharingAddress == nil, !isPairing {
                pairingStatus = "等待屏幕共享连接"
            }
        case .connected(let addresses) where addresses.count > 1:
            receiverStatus = "检测到多个屏幕共享来源，暂停接收"
            if outgoingScreenSharingAddress == nil {
                pairingStatus = "检测到多个操作端，无法确定配对目标"
            }
        case .connected(let addresses):
            let address = addresses.first ?? ""
            if let peer = connectedPeers.first(where: { $0.address == address }) {
                receiverStatus = "屏幕共享来自 \(peer.name)，可接收听写"
                if outgoingScreenSharingAddress == nil {
                    pairingStatus = "已与 \(peer.name) 配对"
                }
            } else {
                receiverStatus = "被操作端待命：\(address)"
                if outgoingScreenSharingAddress == nil {
                    pairingStatus = "等待操作端发起配对"
                }
            }
        }
    }

    func refreshAutomaticTarget() {
        if let address = outgoingScreenSharingAddress {
            routeToScreenSharingTarget(address)
        }
    }

    private func updateIdleRouteStatus() {
        automaticRouteStatus = outgoingScreenSharingAddress == nil
            ? "自动路由：本机输入"
            : "检测到屏幕共享；切到共享窗口后自动远程输入"
    }

    private func routeToScreenSharingTarget(_ address: String) {
        autoRouteTask?.cancel()
        autoRouteTask = Task { [weak self] in
            guard let self else { return }
            let matching = await self.matchingTarget(for: address)
            guard !Task.isCancelled, self.outgoingScreenSharingAddress == address else { return }
            guard let matching else {
                self.connectionStatus = "尚未配对当前屏幕共享电脑"
                self.pairingStatus = "已发现 \(address)，请点击配对当前电脑"
                return
            }
            if self.connectedTargetID != matching.id || !self.client.isConnected {
                if self.isRecording, self.activeOutputRoute?.isLocal == false {
                    await self.endDictation()
                }
                self.settings.selectedTargetID = matching.id
                self.disconnect()
                do {
                    try await self.connect(to: matching)
                    self.errorMessage = ""
                    self.connectionStatus = "已准备远程输入：\(matching.name)"
                    self.pairingStatus = "已配对：\(matching.name)"
                } catch {
                    self.pairingStatus = "自动重连失败"
                    self.fail(error)
                }
            }
        }
    }

    private func isCurrentScreenSharingPeer(_ peer: ConnectedPeer) -> Bool {
        guard let address = incomingScreenSharingAddress else { return false }
        return !peer.address.isEmpty && peer.address == address
    }

    private func receive(_ message: TextMessage, from connectionID: UUID) {
        do {
            switch message.type {
            case .audioStart:
                guard let peer = connectedPeers.first(where: { $0.id == connectionID }),
                      isCurrentScreenSharingPeer(peer) else {
                    let reason = "操作端不是当前屏幕共享连接者"
                    receiverStatus = "已拒绝听写：\(reason)"
                    sendIncomingError(reason, for: message, to: connectionID)
                    return
                }
                guard !isRecording, !isStarting else {
                    let reason = "本机正在听写，暂不接收远程输入"
                    receiverStatus = reason
                    sendIncomingError(reason, for: message, to: connectionID)
                    return
                }
                guard incomingSession == nil else {
                    sendIncomingError("B 端正在完成上一段听写，请稍后重试。", for: message, to: connectionID)
                    return
                }
                injector.end()
                incomingSession = message.sessionId
                activeConnectionID = connectionID
                activeControllerName = connectedPeers.first { $0.id == connectionID }?.name ?? message.senderName
                incomingAudioReady = false
                incomingFailed = false
                incomingProgress = RemoteInputProgress()
                pendingTranscript = nil
                pendingIncomingAudio.removeAll(keepingCapacity: true)
                pendingIncomingAudioBytes = 0
                let request = message.modelRequest ?? ModelRequest(
                    mode: .manual, preferred: .apple, controllerHasDoubaoKey: false
                )
                let decision = SpeechModelSelection.decide(
                    request: request,
                    receiverPreferred: settings.recognitionProvider,
                    receiverHasDoubaoKey: settings.hasDoubaoKey
                )
                configureSpeech(decision.provider)
                receiverInputModeStatus = decision.explanation
                receiverStatus = "正在定位 B 端输入框…"
                publishIncomingProgress(force: true)
                errorMessage = ""
                let sessionID = message.sessionId
                incomingStartTask?.cancel()
                incomingStartTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.injector.beginRemote()
                        guard !Task.isCancelled, self.incomingSession == sessionID else { return }
                        self.incomingProgress.target = self.injector.targetDescription
                        self.receiverStatus = "输入框已定位，正在启动识别…"
                        self.publishIncomingProgress(force: true)
                        do {
                            try await self.speech.startNetwork(
                                locale: Locale(identifier: self.settings.locale)
                            )
                        } catch {
                            guard decision.provider == .doubao else { throw error }
                            self.configureSpeech(.apple)
                            self.receiverInputModeStatus = "豆包连接失败，本次改用 Apple 本地识别"
                            self.receiverStatus = self.receiverInputModeStatus
                            self.publishIncomingProgress(force: true)
                            try await self.speech.startNetwork(
                                locale: Locale(identifier: self.settings.locale)
                            )
                        }
                        guard !Task.isCancelled,
                              self.incomingSession == sessionID,
                              self.activeConnectionID == connectionID else {
                            await self.speech.stop()
                            return
                        }
                        self.incomingAudioReady = true
                        let queued = self.pendingIncomingAudio
                        self.pendingIncomingAudio.removeAll(keepingCapacity: true)
                        self.pendingIncomingAudioBytes = 0
                        for packet in queued {
                            self.speech.appendNetworkAudio(packet)
                        }
                        self.receiverStatus = "正在识别 \(self.activeControllerName) 的网络音频"
                        try? self.server.send(
                            self.makeMessage(session: sessionID, type: .audioReady,
                                             modelDecision: ModelDecision(
                                                provider: self.activeModelStatus.hasPrefix("豆包") ? .doubao : .apple,
                                                explanation: self.receiverInputModeStatus)),
                            to: connectionID
                        )
                        self.incomingStartTask = nil
                    } catch {
                        guard self.incomingSession == sessionID else { return }
                        self.incomingStartTask = nil
                        await self.failIncomingAudio(error)
                    }
                }
            case .audioChunk:
                guard incomingSession == message.sessionId,
                      activeConnectionID == connectionID else { return }
                guard !incomingFailed, let audio = message.audio, !audio.isEmpty,
                      audio.count.isMultiple(of: 4) else { return }
                incomingProgress.receive(audio)
                publishIncomingProgress()
                if incomingAudioReady {
                    speech.appendNetworkAudio(audio)
                } else {
                    pendingIncomingAudio.append(audio)
                    pendingIncomingAudioBytes += audio.count
                    if pendingIncomingAudioBytes > 320_000 {
                        throw BridgeError.transport("B 端模型尚未就绪，音频缓冲已满。请等待模型就绪后重试。")
                    }
                }
            case .audioEnd:
                guard incomingSession == message.sessionId,
                      activeConnectionID == connectionID else { return }
                let sessionID = message.sessionId
                Task { @MainActor [weak self] in
                    await self?.finishIncomingAudio(sessionID: sessionID,
                                                    connectionID: connectionID)
                }
            case .modelProbe:
                let snapshot = ModelCapability(preferred: settings.recognitionProvider,
                                               hasDoubaoKey: settings.hasDoubaoKey,
                                               resourceID: settings.doubaoResourceID)
                try? server.send(makeMessage(session: message.sessionId,
                                             type: .modelCapability,
                                             modelCapability: snapshot), to: connectionID)
            case .hello, .welcome, .rejected, .audioReady, .audioError, .audioStatus,
                 .audioComplete, .modelCapability: break
            }
        } catch {
            Task { @MainActor in await failIncomingAudio(error) }
        }
    }

    private func finishIncomingAudio(sessionID: UUID, connectionID: UUID) async {
        guard incomingSession == sessionID,
              activeConnectionID == connectionID,
              !isStoppingIncoming else { return }
        isStoppingIncoming = true
        receiverStatus = "正在完成远程识别…"
        if let incomingStartTask { await incomingStartTask.value }
        guard incomingSession == sessionID,
              activeConnectionID == connectionID else {
            isStoppingIncoming = false
            return
        }
        if incomingAudioReady {
            await speech.stop()
        }
        if let incomingTranscriptTask { await incomingTranscriptTask.value }
        guard incomingSession == sessionID else { return }
        if incomingFailed {
            clearIncomingAudioSession()
            return
        }
        receiverStatus = incomingProgress.recognizedCharacters == 0
            ? "音频已结束，但未识别到文字"
            : "远程听写已结束"
        publishIncomingProgress(force: true)
        try? server.send(TextMessage(sessionId: sessionID, type: .audioComplete,
                                    token: settings.token, senderID: settings.deviceID,
                                    senderName: settings.deviceName,
                                    reason: "\(receiverStatus) · \(incomingProgress.summary)"),
                         to: connectionID)
        clearIncomingAudioSession()
    }

    private func failIncomingAudio(_ error: Error) async {
        guard incomingSession != nil, !incomingFailed else { return }
        incomingFailed = true
        incomingStartTask?.cancel()
        incomingTranscriptTask?.cancel()
        pendingTranscript = nil
        let failedSession = incomingSession
        let failedConnection = activeConnectionID
        let wasAlreadyStopping = isStoppingIncoming
        isStoppingIncoming = true
        if !wasAlreadyStopping {
            if let incomingStartTask { await incomingStartTask.value }
            if incomingAudioReady { await speech.stop() }
        }
        if let failedSession, let failedConnection {
            let response = TextMessage(
                sessionId: failedSession,
                type: .audioError,
                token: settings.token,
                senderID: settings.deviceID,
                senderName: settings.deviceName,
                reason: "\(error.localizedDescription) · \(incomingProgress.summary)"
            )
            try? server.send(response, to: failedConnection)
        }
        if !wasAlreadyStopping { clearIncomingAudioSession() }
        errorMessage = error.localizedDescription
        receiverStatus = "接收失败：\(error.localizedDescription)"
        remoteProgressStatus = "\(receiverStatus) · \(incomingProgress.summary)"
        speechStatus = "需要处理"
    }

    private func abortIncomingAudio(status: String) async {
        guard incomingSession != nil else {
            receiverStatus = status
            return
        }
        await failIncomingAudio(BridgeError.transport(status))
        receiverStatus = status
    }

    private func clearIncomingAudioSession() {
        injector.end()
        incomingTranscriptTask?.cancel()
        incomingTranscriptTask = nil
        pendingTranscript = nil
        incomingStartTask = nil
        incomingAudioReady = false
        pendingIncomingAudio.removeAll(keepingCapacity: false)
        pendingIncomingAudioBytes = 0
        incomingSession = nil
        activeConnectionID = nil
        activeControllerName = ""
        isStoppingIncoming = false
    }

    private func sendIncomingError(_ reason: String,
                                   for request: TextMessage,
                                   to connectionID: UUID) {
        let response = TextMessage(
            sessionId: request.sessionId,
            type: .audioError,
            token: settings.token,
            senderID: settings.deviceID,
            senderName: settings.deviceName,
            reason: reason
        )
        try? server.send(response, to: connectionID)
    }

    private func prepareRemoteSession(_ session: UUID) async throws {
        try await withCheckedThrowingContinuation { continuation in
            remoteReadyContinuation = continuation
            let selection = ModelRequest(mode: settings.modelSelectionMode,
                                         preferred: settings.recognitionProvider,
                                         controllerHasDoubaoKey: settings.hasDoubaoKey)
            do { try client.send(makeMessage(session: session, type: .audioStart,
                                             modelRequest: selection)) }
            catch {
                remoteReadyContinuation = nil
                continuation.resume(throwing: error)
                return
            }
            remoteReadyTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.outgoingSession == session else { return }
                self.remoteReadyContinuation?.resume(throwing: BridgeError.transport(
                    "B 端准备超时：\(self.remoteProgressStatus)"))
                self.remoteReadyContinuation = nil
            }
        }
    }

    private func clearOutgoingRemoteSession() {
        remoteReadyTimeout?.cancel()
        remoteFinishTimeout?.cancel()
        remoteReadyContinuation?.resume(throwing: BridgeError.transport("远程听写已结束。"))
        remoteReadyContinuation = nil
        outgoingSession = nil
        activeOutputRoute = nil
        isRecording = false
        overlay.hide()
        updateIdleRouteStatus()
    }

    private func receiveRemoteStatus(_ message: TextMessage) {
        if message.type == .modelCapability, let capability = message.modelCapability {
            remoteCapability = capability
            updateRemoteModelStatus()
            return
        }
        guard message.sessionId == outgoingSession,
              activeOutputRoute?.isLocal == false else { return }
        switch message.type {
        case .audioReady:
            if let choice = message.modelDecision {
                remoteModelStatus = choice.explanation
                activeModelStatus = "B：\(choice.provider.title)"
            }
            remoteReadyTimeout?.cancel()
            connectionStatus = "B 端识别已启动"
            remoteReadyContinuation?.resume()
            remoteReadyContinuation = nil
        case .audioStatus:
            remoteProgressStatus = message.reason ?? "等待 B 端状态"
        case .audioComplete:
            remoteProgressStatus = message.reason ?? "B 端已结束"
            clearOutgoingRemoteSession()
            speechStatus = readySpeechStatus
        case .audioError:
            let error = BridgeError.transport(message.reason ?? "B 端远程输入失败。")
            remoteProgressStatus = error.localizedDescription
            remoteReadyTimeout?.cancel()
            if let continuation = remoteReadyContinuation {
                remoteReadyContinuation = nil
                continuation.resume(throwing: error)
            } else {
                Task { @MainActor in
                    await self.remoteAudioCapture.stop()
                    self.clearOutgoingRemoteSession()
                    self.fail(error)
                }
            }
        default: break
        }
    }

    private func publishIncomingProgress(force: Bool = false) {
        guard let session = incomingSession, let connection = activeConnectionID else { return }
        remoteProgressStatus = "\(receiverStatus) · \(incomingProgress.summary)"
        guard force || Date().timeIntervalSince(lastProgressSent) >= 0.5 else { return }
        lastProgressSent = Date()
        try? server.send(TextMessage(sessionId: session, type: .audioStatus,
                                    token: settings.token, senderID: settings.deviceID,
                                    senderName: settings.deviceName, reason: remoteProgressStatus),
                         to: connection)
    }

    private func startIncomingTranscriptWriter() {
        guard incomingTranscriptTask == nil, let session = incomingSession else { return }
        incomingTranscriptTask = Task { [weak self] in
            guard let self else { return }
            while self.incomingSession == session, !Task.isCancelled, !self.incomingFailed,
                  let text = self.pendingTranscript {
                self.pendingTranscript = nil
                do {
                    try await self.injector.updateRemote(text)
                    guard self.incomingSession == session, !Task.isCancelled else { return }
                    self.incomingProgress.writtenCharacters = text.count
                    self.incomingProgress.writeStatus = self.injector.verificationStatus
                    self.publishIncomingProgress(force: true)
                } catch {
                    guard self.incomingSession == session, !Task.isCancelled else { return }
                    await self.failIncomingAudio(error)
                    return
                }
            }
            if self.incomingSession == session { self.incomingTranscriptTask = nil }
        }
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        speechStatus = "需要处理"
    }
}
