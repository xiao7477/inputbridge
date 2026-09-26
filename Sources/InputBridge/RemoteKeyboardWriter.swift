import ApplicationServices

@MainActor
final class RemoteKeyboardWriter {
    private let source: CGEventSource

    init() throws {
        guard let source = CGEventSource(stateID: .privateState) else {
            throw BridgeError.injection("B 端无法建立独立键盘事件源。")
        }
        self.source = source
    }

    func post(_ code: CGKeyCode, unicode: String?, to pid: pid_t) throws {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw BridgeError.injection("B 端无法创建键盘输入事件。")
        }
        for event in [down, up] {
            if let unicode {
                let units = Array(unicode.utf16)
                units.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
            }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: InputBridgeEventMarker.keyboardInjection)
            event.postToPid(pid)
        }
    }
}
