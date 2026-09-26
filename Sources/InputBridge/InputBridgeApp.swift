import AppKit
import AVFoundation
import Speech
import SwiftUI

@main
struct InputBridgeApp: App {
    @StateObject private var model = BridgeModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model, settings: model.settings)
        } label: {
            MenuBarStatusIcon(
                isRecording: model.isRecording,
                isReceiving: model.activeConnectionID != nil,
                isBeingScreenShared: model.isBeingScreenShared
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model, settings: model.settings)
        }
        .windowResizability(.contentSize)
    }
}

private struct MenuBarStatusIcon: View {
    let isRecording: Bool
    let isReceiving: Bool
    let isBeingScreenShared: Bool

    var body: some View {
        if isReceiving || isBeingScreenShared {
            Image(systemName: "waveform")
                .renderingMode(.original)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.yellow)
                .accessibilityLabel(isReceiving
                    ? "语音输入共享正在接收远程听写"
                    : "语音输入共享处于被操作端待命状态")
        } else {
            Image(systemName: isRecording ? "waveform" : "mic")
                .accessibilityLabel(isRecording ? "语音输入共享正在听写" : "语音输入共享")
        }
    }
}

private struct MenuBarView: View {
    @ObservedObject var model: BridgeModel
    @ObservedObject var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    private var legacySpeechAuthorization: SFSpeechRecognizerAuthorizationStatus? {
        if #available(macOS 26.0, *) { return nil }
        return SFSpeechRecognizer.authorizationStatus()
    }

    private var authorizationSummary: String {
        var parts = [
            TextInjector.hasPermission ? "辅助功能已授权" : "辅助功能未授权",
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                ? "麦克风已授权" : "麦克风未授权"
        ]
        if let status = legacySpeechAuthorization {
            switch status {
            case .authorized: parts.append("Apple 识别已授权")
            case .notDetermined: parts.append("Apple 识别尚未请求授权")
            case .denied: parts.append("Apple 识别已拒绝")
            case .restricted: parts.append("Apple 识别受系统限制")
            @unknown default: parts.append("Apple 识别授权状态未知")
            }
        }
        return parts.joined(separator: " · ")
    }

    private var allPermissionsGranted: Bool {
        TextInjector.hasPermission &&
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized &&
            (legacySpeechAuthorization == nil || legacySpeechAuthorization == .authorized)
    }

    private var connectionSummary: String {
        if model.activeConnectionID != nil { return "正在接收远程语音" }
        if model.isPassiveReceiver { return model.receiverStatus }
        if model.outgoingScreenSharingAddress != nil { return model.connectionStatus }
        return "本机输入"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
                Text("语音输入共享")
                    .font(.headline)
                Spacer()
                Text(model.activeConnectionID != nil
                     ? "远程接收中"
                     : (model.isBeingScreenShared
                        ? "被操作端待命"
                        : (model.isRecording ? "听写中" : "就绪")))
                    .font(.caption)
                    .foregroundStyle(model.activeConnectionID != nil || model.isBeingScreenShared
                                     ? Color.yellow
                                     : (model.isRecording ? Color.green : Color.secondary))
            }

            Divider()

            HStack {
                Text("识别模型")
                Spacer()
                Picker("识别模型", selection: $settings.recognitionProvider) {
                    Text("Apple 本地识别").tag(RecognitionProvider.apple)
                    Text(settings.hasDoubaoKey ? "豆包语音 2.0" : "豆包语音 2.0（先配置密钥）")
                        .tag(RecognitionProvider.doubao)
                        .disabled(!settings.hasDoubaoKey)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
                .disabled(model.isRecording)
                .onChange(of: settings.recognitionProvider) { _, _ in
                    model.refreshModelCapability()
                }
            }

            if model.isPassiveReceiver {
                Label("被操作端只接收网络音频，本机快捷键已暂停", systemImage: "waveform.badge.mic")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("快捷键")
                        Spacer()
                        Button(model.isCapturingShortcut ? "请按快捷键…" : settings.shortcut.title) {
                            if model.isCapturingShortcut {
                                model.cancelShortcutCapture()
                            } else {
                                model.startShortcutCapture()
                            }
                        }
                    }

                    Picker("触发方式", selection: Binding(
                        get: { settings.shortcutMode },
                        set: { model.setShortcutMode($0) }
                    )) {
                        Text("单击").tag(ShortcutActivationMode.toggle)
                        Text("长按").tag(ShortcutActivationMode.hold)
                    }
                    .pickerStyle(.segmented)

                    if model.isCapturingShortcut {
                        Text("直接按下新快捷键；只用修饰键时，松开全部按键完成。按 Esc 取消。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("状态")
                    .font(.subheadline.bold())
                StatusRow(label: "授权", value: authorizationSummary,
                          color: allPermissionsGranted ? .green : .orange, lineLimit: nil)
                StatusRow(label: "连接", value: connectionSummary, lineLimit: nil)
                StatusRow(label: "错误", value: model.errorMessage.isEmpty ? "无" : model.errorMessage,
                          color: model.errorMessage.isEmpty ? .secondary : .red,
                          lineLimit: nil)
            }

            Divider()

            HStack {
                if !TextInjector.hasPermission {
                    Button("申请权限") {
                        Task { await model.requestPermissions() }
                    }
                }
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                Spacer()
                if model.isRecording {
                    Button("停止") {
                        Task { await model.endDictation() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 380)
        .onDisappear {
            model.cancelShortcutCapture()
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: BridgeModel
    @ObservedObject var settings: AppSettings
    @State private var doubaoKeyDraft = ""
    @StateObject private var updater = GitHubUpdater()

    private func targetField(_ keyPath: WritableKeyPath<RemoteTarget, String>) -> Binding<String> {
        Binding(
            get: { settings.selectedTarget?[keyPath: keyPath] ?? "" },
            set: { value in
                settings.updateSelectedTarget { $0[keyPath: keyPath] = value }
                model.disconnect()
                model.refreshAutomaticTarget()
            }
        )
    }

    var body: some View {
        Form {
            Section("本机") {
                Picker("识别语言", selection: $settings.locale) {
                    Text("简体中文").tag("zh-CN")
                    Text("English (US)").tag("en-US")
                }

                HStack {
                    Picker("麦克风", selection: $settings.microphoneUID) {
                        Text("跟随系统").tag("")
                        ForEach(model.availableMicrophones) { microphone in
                            Text(microphone.name).tag(microphone.uid)
                        }
                        if !settings.microphoneUID.isEmpty,
                           !model.availableMicrophones.contains(where: {
                               $0.uid == settings.microphoneUID
                           }) {
                            Text("所选设备不可用").tag(settings.microphoneUID)
                        }
                    }
                    .disabled(model.isRecording)

                    Button {
                        model.refreshMicrophones()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("重新扫描麦克风")
                }

                TextField("这台 Mac 的名称", text: $settings.deviceName)

                TextField("接收端口", text: $settings.listenPortText)
                    .onChange(of: settings.listenPortText) { _, _ in
                        model.startReceiver()
                    }

                Toggle("开机时自动启动", isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ))

                HStack {
                    Text("开机启动：\(model.launchAtLoginStatus)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.launchAtLoginNeedsApproval {
                        Button("前往系统设置允许") {
                            model.openLoginItemSettings()
                        }
                    }
                }

                LabeledContent("辅助功能") {
                    Text(TextInjector.hasPermission ? "已授权" : "未授权")
                        .foregroundStyle(TextInjector.hasPermission ? .green : .red)
                }

                Button("检查并申请所需权限") {
                    Task { await model.requestPermissions() }
                }
            }

            Section("语音识别模型") {
                Picker("首选模型", selection: $settings.recognitionProvider) {
                    Text("Apple 本地识别").tag(RecognitionProvider.apple)
                    Text(settings.hasDoubaoKey ? "豆包语音 2.0" : "豆包语音 2.0（先配置密钥）")
                        .tag(RecognitionProvider.doubao)
                        .disabled(!settings.hasDoubaoKey)
                }
                .onChange(of: settings.recognitionProvider) { _, _ in
                    model.refreshModelCapability()
                }

                Picker("远程模型选择", selection: $settings.modelSelectionMode) {
                    Text("自动").tag(ModelSelectionMode.automatic)
                    Text("手动").tag(ModelSelectionMode.manual)
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.modelSelectionMode) { _, _ in
                    model.refreshModelCapability()
                }

                Text("由操作端 A 设置远程选择模式；B 按 A 的模式决定本次识别引擎。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(settings.modelSelectionMode == .automatic
                     ? "自动：A 的首选模型为豆包且两端都已配置时，B 使用豆包；否则 B 自动使用 Apple 本地识别。"
                     : "手动：本机输入使用本机模型；远程输入由 B 自己的模型设置决定。B 未配置豆包时自动使用 Apple。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("豆包 2.0 资源", selection: $settings.doubaoResourceID) {
                    Text("小时版").tag("volc.seedasr.sauc.duration")
                    Text("并发版").tag("volc.seedasr.sauc.concurrent")
                }
                .onChange(of: settings.doubaoResourceID) { _, _ in
                    model.refreshModelCapability()
                }

                HStack {
                    SecureField("豆包 API Key", text: $doubaoKeyDraft)
                        .textContentType(.password)
                    Button("保存密钥") {
                        settings.doubaoAPIKey = doubaoKeyDraft
                        model.refreshModelCapability()
                    }
                    .disabled(doubaoKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              doubaoKeyDraft == settings.doubaoAPIKey)
                    Button("清除") {
                        doubaoKeyDraft = ""
                        settings.doubaoAPIKey = ""
                        model.refreshModelCapability()
                    }
                    .disabled(!settings.hasDoubaoKey)
                }
                LabeledContent("豆包密钥", value: settings.doubaoCredentialStatus)
                Text("密钥仅保存在这台 Mac 的钥匙串。每台想使用豆包识别的 Mac 都需自行配置；不会在电脑间传输密钥。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("屏幕共享配对") {
                if let address = model.outgoingScreenSharingAddress {
                    LabeledContent("当前操作目标", value: address)

                    HStack {
                        Button {
                            Task { await model.pairCurrentScreenSharingTarget() }
                        } label: {
                            if model.isPairing {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("正在配对…")
                                }
                            } else {
                                Text("配对当前电脑")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isPairing)

                        Text(model.pairingStatus)
                            .font(.caption)
                            .foregroundStyle(model.pairingStatus.contains("成功") ||
                                             model.pairingStatus.hasPrefix("已配对")
                                             ? Color.green : Color.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let address = model.incomingScreenSharingAddress {
                    LabeledContent("当前状态") {
                        Label("被操作端待命", systemImage: "circle.fill")
                            .foregroundStyle(.yellow)
                    }
                    LabeledContent("操作端地址", value: address)
                    Text("无需在这台 Mac 操作。请在操作端点击“配对当前电脑”，这里会自动接受并显示结果。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.pairingStatus)
                        .font(.caption)
                        .foregroundStyle(model.pairingStatus.hasPrefix("已") ? Color.green : Color.secondary)
                } else {
                    Text("先用 macOS“屏幕共享”连接另一台 Mac。操作端会自动找到当前目标，被操作端会自动进入黄色待命状态。")
                        .foregroundStyle(.secondary)
                }
            }

            Section("已保存的远程电脑") {
                HStack {
                    if settings.targets.isEmpty {
                        Text("配对成功后会自动出现在这里")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("当前目标", selection: $settings.selectedTargetID) {
                            ForEach(settings.targets) { target in
                                Text(target.name).tag(target.id as UUID?)
                            }
                        }
                        .onChange(of: settings.selectedTargetID) { _, _ in
                            model.disconnect()
                            model.refreshAutomaticTarget()
                        }
                    }
                    Spacer()
                    Button("手动添加") {
                        settings.addTarget()
                        model.disconnect()
                        model.refreshAutomaticTarget()
                    }
                    Button("删除") {
                        settings.removeSelectedTarget()
                        model.disconnect()
                        model.refreshAutomaticTarget()
                    }
                    .disabled(settings.selectedTarget == nil)
                }

                if settings.selectedTarget != nil {
                    TextField("名称", text: targetField(\.name))
                    TextField("局域网 IP 或 Tailscale 名称", text: targetField(\.host))
                    TextField("端口", text: targetField(\.portText))
                }

                Text("通常不需要手动设置。保留这里是为了 Tailscale 名称、非默认端口等特殊网络。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("软件更新") {
                HStack {
                    Button("自动更新") {
                        Task { await updater.checkAndInstall() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.isRunning || model.isRecording || model.activeConnectionID != nil)
                    if updater.isRunning { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(updater.status)
                        .font(.caption)
                        .foregroundStyle(updater.status.hasPrefix("更新失败") ? .red : .secondary)
                        .multilineTextAlignment(.trailing)
                }
                Text("从 GitHub 最新正式版下载并校验更新包，安装后自动重启。首次安装这版 App 的其他 Mac 仍需手动复制一次。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("详细状态") {
                LabeledContent("App 版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")）")
                LabeledContent("语音识别", value: model.speechStatus)
                LabeledContent("本次实际模型", value: model.activeModelStatus)
                LabeledContent("远程模型", value: model.remoteModelStatus)
                LabeledContent("麦克风", value: model.selectedMicrophoneStatus)
                LabeledContent("自动输入", value: model.automaticRouteStatus)
                LabeledContent("远程发送", value: model.connectionStatus)
                LabeledContent("远程接收", value: model.receiverStatus)
                LabeledContent("接收识别", value: model.receiverInputModeStatus)
                LabeledContent("远程链路", value: model.remoteProgressStatus)
                LabeledContent("已记住操作端", value: "\(settings.pairedControllerIDs.count) 台")
                LabeledContent("当前在线操作端", value: "\(model.connectedPeers.count) 台")
                LabeledContent(
                    "当前屏幕共享目标",
                    value: model.outgoingScreenSharingAddress ?? "未检测到"
                )
                LabeledContent(
                    "当前屏幕共享来源",
                    value: model.incomingScreenSharingAddress ?? "未检测到"
                )

                ForEach(model.connectedPeers) { peer in
                    HStack {
                        Circle()
                            .fill(peer.address == model.incomingScreenSharingAddress ? .green : .gray)
                            .frame(width: 7, height: 7)
                        Text(peer.name)
                        Spacer()
                        if peer.id == model.activeConnectionID {
                            Text("正在接收")
                                .foregroundStyle(.green)
                        } else {
                            Text(peer.address)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }

                if !settings.pairedControllerIDs.isEmpty {
                    Button("清除被操作端配对记录") {
                        settings.forgetPairedControllers()
                    }
                }

                if !model.errorMessage.isEmpty {
                    Text(model.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 720)
        .onAppear {
            doubaoKeyDraft = settings.doubaoAPIKey
            model.refreshModelCapability()
            model.refreshMicrophones()
            model.refreshLaunchAtLoginStatus()
        }
    }
}

private struct StatusRow: View {
    let label: String
    let value: String
    var color: Color = .secondary
    var lineLimit: Int? = 2

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .lineLimit(lineLimit)
        }
        .font(.caption)
    }
}
