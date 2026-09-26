import AppKit
import ApplicationServices

@MainActor
final class TextInjector {
    private static var didPromptThisRun = false
    private var targetProcessID: pid_t?
    private var insertedText = ""
    private var remoteApplication: AXUIElement?
    private var remoteEditor: AXUIElement?
    private var remoteApplicationPID: pid_t?
    private var remoteWriter: RemoteKeyboardWriter?
    private(set) var targetDescription = ""
    private(set) var verificationStatus = "尚未写入"

    static var hasPermission: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestPermission() -> Bool {
        if hasPermission { return true }
        guard !didPromptThisRun else { return false }
        didPromptThisRun = true
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func begin() throws {
        if !Self.hasPermission {
            Self.requestPermission()
        }
        guard Self.hasPermission else {
            throw BridgeError.permission("此版本尚未获得辅助功能权限。若系统设置已勾选，请移除旧的“语音输入共享”条目，重新添加当前 App，勾选后退出并重开。")
        }
        guard let target = focusedElement(),
              let processID = processID(of: target),
              !isKnownNonEditable(target) else {
            throw BridgeError.noFocusedText
        }
        targetProcessID = processID
        insertedText = ""
    }

    /// Resolve the focused editor inside Electron/Chromium before starting recognition.
    /// A window/container alone is not evidence of an editable field.
    func beginRemote() async throws {
        end()
        guard Self.hasPermission else {
            throw BridgeError.permission("B 端未获得辅助功能权限，无法写入输入框。")
        }
        let system = AXUIElementCreateSystemWide()
        let app = copyElementAttribute(kAXFocusedApplicationAttribute as CFString, from: system)
            ?? NSWorkspace.shared.frontmostApplication.map {
                AXUIElementCreateApplication($0.processIdentifier)
            }
        guard let app, let pid = processID(of: app), pid != ProcessInfo.processInfo.processIdentifier else {
            throw BridgeError.injection("B 端焦点仍在语音输入共享菜单，请关闭菜单后点选目标输入框。")
        }
        AXUIElementSetMessagingTimeout(app, 0.25)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "目标 App"
        // Electron documents AXManualAccessibility; Chromium uses AXEnhancedUserInterface.
        // Unsupported attributes on native applications return an error and are ignored.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var lastRole = "未返回焦点元素"
        for attempt in 0..<6 {
            try Task.checkCancellation()
            guard focusedApplicationPID() == pid else {
                throw BridgeError.injection("B 端前台 App 已改变，请重新开始听写。")
            }
            if let element = remoteFocusedElement(in: app) {
                lastRole = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? "未知控件"
                let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: element)
                guard subrole != "AXSecureTextField" else {
                    throw BridgeError.injection("不能向密码输入框写入语音。")
                }
                if !isKnownNonEditable(element), let elementPID = processID(of: element) {
                    targetProcessID = elementPID
                    remoteApplication = app
                    remoteEditor = element
                    verificationStatus = "尚未写入"
                    remoteApplicationPID = pid
                    remoteWriter = try RemoteKeyboardWriter()
                    insertedText = ""
                    targetDescription = "\(name) / \(lastRole)"
                    return
                }
            }
            if attempt < 5 { try await Task.sleep(for: .milliseconds(100)) }
        }
        throw BridgeError.injection("B 端 \(name) 未提供可输入焦点（\(lastRole)）。已启用网页辅助功能，请点进编辑区后重试。")
    }

    /// Remote events target the focused application's session, not the global HID stream.
    /// Each update is serialized by BridgeModel and read back before revising it again.
    func updateRemote(_ text: String) async throws {
        guard let app = remoteApplication, let pid = remoteApplicationPID,
              let remoteWriter else {
            throw BridgeError.noFocusedText
        }
        let focused = try checkedRemoteFocus(app: app, pid: pid)
        let before = stringAttribute(kAXValueAttribute as CFString, from: focused)
        let prefix = TextEditPlanner.commonPrefixLength(insertedText, text)
        let deletions = insertedText.count - prefix
        let addition = String(text.dropFirst(prefix))
        guard deletions > 0 || !addition.isEmpty else { return }
        for _ in 0..<deletions {
            _ = try checkedRemoteFocus(app: app, pid: pid)
            try remoteWriter.post(51, unicode: nil, to: pid)
            try await Task.sleep(for: .milliseconds(3))
        }
        for character in addition {
            try Task.checkCancellation()
            _ = try checkedRemoteFocus(app: app, pid: pid)
            try remoteWriter.post(0, unicode: String(character), to: pid)
            try await Task.sleep(for: .milliseconds(3))
        }
        // A successful CGEvent.post has no delivery acknowledgement. Never call it verified.
        // An unchanged readable field is a hard failure: do not backspace it on the next result.
        if let before {
            for attempt in 0..<5 {
                try await Task.sleep(for: .milliseconds(100))
                let current = try checkedRemoteFocus(app: app, pid: pid)
                if let after = stringAttribute(kAXValueAttribute as CFString, from: current), after != before {
                    insertedText = text
                    verificationStatus = "输入框已变化（\(text.count) 字）"
                    return
                }
                if attempt == 4 {
                    throw BridgeError.injection("B 端已识别 \(text.count) 字，但 \(targetDescription) 输入框没有变化。已停止，避免继续退格修改原文。")
                }
            }
        } else {
            try await Task.sleep(for: .milliseconds(100))
            _ = try checkedRemoteFocus(app: app, pid: pid)
            insertedText = text
            verificationStatus = "已投递 \(text.count) 字；此控件不提供文字回读"
        }
    }

    private func focusedApplicationPID() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        if let app = copyElementAttribute(kAXFocusedApplicationAttribute as CFString, from: system) {
            return processID(of: app)
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func remoteFocusedElement(in app: AXUIElement) -> AXUIElement? {
        // Ask the application first. A system-wide query can expose a window wrapper.
        let appFocus = copyElementAttribute(kAXFocusedUIElementAttribute as CFString, from: app)
        var candidates = [AXUIElement]()
        if let appFocus { candidates.append(appFocus) }
        if let systemFocus = focusedElement() { candidates.append(systemFocus) }
        for candidate in candidates {
            if !isKnownNonEditable(candidate),
               stringAttribute(kAXRoleAttribute as CFString, from: candidate) != "AXStaticText" { return candidate }
            if let child = copyElementAttribute(kAXFocusedUIElementAttribute as CFString, from: candidate),
               !isKnownNonEditable(child) { return child }
        }
        return appFocus ?? candidates.first
    }

    private func checkedRemoteFocus(app: AXUIElement, pid: pid_t) throws -> AXUIElement {
        guard focusedApplicationPID() == pid,
              let focused = remoteFocusedElement(in: app),
              processID(of: focused) == targetProcessID,
              let remoteEditor, CFEqual(focused, remoteEditor),
              !isKnownNonEditable(focused),
              stringAttribute(kAXSubroleAttribute as CFString, from: focused) != "AXSecureTextField" else {
            throw BridgeError.injection("B 端输入焦点已改变，本次语音输入已停止。")
        }
        return focused
    }

    func update(_ text: String) throws {
        guard let targetProcessID else { throw BridgeError.noFocusedText }
        try checkFocus(processID: targetProcessID)
        try updateKeyboard(text)
        insertedText = text
    }

    func end() {
        remoteApplication = nil
        remoteEditor = nil
        remoteApplicationPID = nil
        remoteWriter = nil
        targetProcessID = nil
        insertedText = ""
    }

    private func checkFocus(processID: pid_t) throws {
        guard let focused = focusedElement(),
              self.processID(of: focused) == processID,
              !isKnownNonEditable(focused) else {
            throw BridgeError.injection("输入焦点已改变，本次语音输入已停止。")
        }
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        if let focused = copyElementAttribute(kAXFocusedUIElementAttribute as CFString,
                                              from: system) {
            return focused
        }

        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return copyElementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: AXUIElementCreateApplication(app.processIdentifier)
        )
    }

    private func copyElementAttribute(_ attribute: CFString,
                                      from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func processID(of element: AXUIElement) -> pid_t? {
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success, processID > 0 else { return nil }
        return processID
    }

    private func isKnownNonEditable(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute as CFString, from: element) else {
            return false
        }
        return [
            "AXApplication", "AXWindow", "AXButton", "AXCheckBox", "AXRadioButton",
            "AXPopUpButton", "AXMenu", "AXMenuItem", "AXSlider", "AXScrollBar", "AXToolbar"
        ].contains(role)
    }

    private func stringAttribute(_ attribute: CFString,
                                 from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func updateKeyboard(_ text: String) throws {
        let prefix = TextEditPlanner.commonPrefixLength(insertedText, text)
        for _ in 0..<(insertedText.count - prefix) { postKey(51) }
        for chunk in String(text.dropFirst(prefix)).utf16Chunks(maxLength: 20) {
            var units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw BridgeError.injection("无法创建键盘输入事件。")
            }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.flags = []
            up.flags = []
            down.setIntegerValueField(.eventSourceUserData, value: InputBridgeEventMarker.keyboardInjection)
            up.setIntegerValueField(.eventSourceUserData, value: InputBridgeEventMarker.keyboardInjection)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func postKey(_ key: CGKeyCode) {
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
           let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) {
            down.flags = []
            up.flags = []
            down.setIntegerValueField(.eventSourceUserData, value: InputBridgeEventMarker.keyboardInjection)
            up.setIntegerValueField(.eventSourceUserData, value: InputBridgeEventMarker.keyboardInjection)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

}

private extension String {
    func utf16Chunks(maxLength: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in self {
            if (current + String(character)).utf16.count > maxLength, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
