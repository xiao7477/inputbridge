import Foundation
import Security

struct RemoteTarget: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var portText: String

    init(id: UUID = UUID(), name: String = "新 Mac", host: String = "", portText: String = "47831") {
        self.id = id
        self.name = name
        self.host = host
        self.portText = portText
    }

    var port: UInt16? { UInt16(portText).flatMap { $0 > 0 ? $0 : nil } }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var targets: [RemoteTarget] { didSet { save() } }
    @Published var selectedTargetID: UUID? { didSet { save() } }
    @Published var listenPortText: String { didSet { save() } }
    @Published var token: String { didSet { save() } }
    @Published var locale: String { didSet { save() } }
    @Published var recognitionProvider: RecognitionProvider { didSet { save() } }
    @Published var modelSelectionMode: ModelSelectionMode { didSet { save() } }
    @Published var doubaoResourceID: String { didSet { save() } }
    @Published var doubaoAPIKey: String {
        didSet {
            let result = DoubaoCredentialStore.save(doubaoAPIKey)
            if result != errSecSuccess && result != errSecItemNotFound {
                doubaoCredentialStatus = "钥匙串保存失败（\(result)）"
            } else {
                doubaoCredentialStatus = doubaoAPIKey.isEmpty ? "未配置" : "已保存在本机钥匙串"
            }
        }
    }
    @Published var doubaoCredentialStatus: String
    @Published var microphoneUID: String { didSet { save() } }
    @Published var shortcut: GlobalShortcut { didSet { save() } }
    @Published var shortcutMode: ShortcutActivationMode { didSet { save() } }
    @Published var deviceName: String { didSet { save() } }
    @Published private(set) var pairedControllerIDs: Set<UUID> { didSet { save() } }
    let deviceID: UUID

    var hasDoubaoKey: Bool {
        doubaoCredentialStatus == "已保存在本机钥匙串" &&
            !doubaoAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var listenPort: UInt16? { UInt16(listenPortText).flatMap { $0 > 0 ? $0 : nil } }
    var selectedTarget: RemoteTarget? { targets.first { $0.id == selectedTargetID } }

    init(defaults: UserDefaults = .standard) {
        let loadedTargets: [RemoteTarget]
        if let data = defaults.data(forKey: "targets"),
           let decoded = try? JSONDecoder().decode([RemoteTarget].self, from: data) {
            loadedTargets = decoded
        } else {
            let oldHost = defaults.string(forKey: "host") ?? ""
            loadedTargets = oldHost.isEmpty ? [] : [RemoteTarget(name: "原目标 Mac", host: oldHost,
                                                                  portText: defaults.string(forKey: "port") ?? "47831")]
        }
        targets = loadedTargets
        selectedTargetID = defaults.string(forKey: "selectedTargetID").flatMap(UUID.init(uuidString:)) ?? loadedTargets.first?.id
        listenPortText = defaults.string(forKey: "listenPort") ?? "47831"
        token = defaults.string(forKey: "token") ?? ""
        locale = defaults.string(forKey: "locale") ?? "zh-CN"
        recognitionProvider = RecognitionProvider(rawValue: defaults.string(forKey: "recognitionProvider") ?? "apple") ?? .apple
        modelSelectionMode = ModelSelectionMode(rawValue: defaults.string(forKey: "modelSelectionMode") ?? "automatic") ?? .automatic
        doubaoResourceID = defaults.string(forKey: "doubaoResourceID") ?? "volc.seedasr.sauc.duration"
        let storedDoubaoKey = DoubaoCredentialStore.load()
        doubaoAPIKey = storedDoubaoKey
        doubaoCredentialStatus = storedDoubaoKey.isEmpty ? "未配置" : "已保存在本机钥匙串"
        microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        if let data = defaults.data(forKey: "shortcutV2"),
           let decoded = try? JSONDecoder().decode(GlobalShortcut.self, from: data) {
            if !defaults.bool(forKey: "repairedDuplicatedModifierSidesV043") {
                let repaired = decoded.repairingDuplicatedModifierSides()
                shortcut = repaired
                defaults.set(try? JSONEncoder().encode(repaired), forKey: "shortcutV2")
            } else {
                shortcut = decoded
            }
        } else {
            shortcut = .defaultShortcut
        }
        defaults.set(true, forKey: "repairedDuplicatedModifierSidesV043")
        shortcutMode = ShortcutActivationMode(rawValue: defaults.string(forKey: "shortcutMode") ?? "hold") ?? .hold
        deviceName = defaults.string(forKey: "deviceName") ?? ProcessInfo.processInfo.hostName
        pairedControllerIDs = Set(
            (defaults.stringArray(forKey: "pairedControllerIDs") ?? []).compactMap(UUID.init(uuidString:))
        )
        deviceID = defaults.string(forKey: "deviceID").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(deviceID.uuidString, forKey: "deviceID")
    }

    func addTarget() {
        let target = RemoteTarget()
        targets.append(target)
        selectedTargetID = target.id
    }

    func removeSelectedTarget() {
        targets.removeAll { $0.id == selectedTargetID }
        selectedTargetID = targets.first?.id
    }

    func updateSelectedTarget(_ change: (inout RemoteTarget) -> Void) {
        guard let index = targets.firstIndex(where: { $0.id == selectedTargetID }) else { return }
        var copy = targets
        change(&copy[index])
        targets = copy
    }

    @discardableResult
    func selectOrAddTarget(host: String, portText: String = "47831") -> RemoteTarget {
        let normalizedHost = ScreenSharingMonitor.normalize(
            host.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if let target = targets.first(where: {
            ScreenSharingMonitor.normalize($0.host) == normalizedHost
        }) {
            selectedTargetID = target.id
            return target
        }

        let target = RemoteTarget(
            name: "Mac \(normalizedHost)",
            host: normalizedHost,
            portText: portText
        )
        targets.append(target)
        selectedTargetID = target.id
        return target
    }

    func makeToken() { token = UUID().uuidString.replacingOccurrences(of: "-", with: "") }

    func isPairedController(_ deviceID: UUID) -> Bool {
        pairedControllerIDs.contains(deviceID)
    }

    func rememberPairedController(_ deviceID: UUID) {
        pairedControllerIDs.insert(deviceID)
    }

    func forgetPairedControllers() {
        pairedControllerIDs.removeAll()
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(targets), forKey: "targets")
        defaults.set(selectedTargetID?.uuidString, forKey: "selectedTargetID")
        defaults.set(listenPortText, forKey: "listenPort")
        defaults.set(token, forKey: "token")
        defaults.set(locale, forKey: "locale")
        defaults.set(recognitionProvider.rawValue, forKey: "recognitionProvider")
        defaults.set(modelSelectionMode.rawValue, forKey: "modelSelectionMode")
        defaults.set(doubaoResourceID, forKey: "doubaoResourceID")
        defaults.set(microphoneUID, forKey: "microphoneUID")
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcutV2")
        defaults.set(shortcutMode.rawValue, forKey: "shortcutMode")
        defaults.set(deviceName, forKey: "deviceName")
        defaults.set(pairedControllerIDs.map(\.uuidString).sorted(), forKey: "pairedControllerIDs")
    }
}
