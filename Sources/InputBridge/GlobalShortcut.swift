import AppKit
import Carbon.HIToolbox
import Foundation

enum InputBridgeEventMarker {
    static let keyboardInjection: Int64 = 0x494252474B4559
}

enum ShortcutActivationMode: String, Codable, CaseIterable, Identifiable {
    case hold, toggle

    var id: String { rawValue }
    var title: String {
        switch self {
        case .hold: "长按"
        case .toggle: "单击"
        }
    }
}

struct GlobalShortcut: Codable, Equatable {
    let modifierKeyCodes: [UInt16]
    let keyCode: UInt16?
    let keyLabel: String

    static let defaultShortcut = GlobalShortcut(modifierKeyCodes: [UInt16(kVK_Option)],
                                                keyCode: UInt16(kVK_Space), keyLabel: "Space")

    static let modifierOrder: [UInt16] = [
        UInt16(kVK_Control), UInt16(kVK_RightControl),
        UInt16(kVK_Option), UInt16(kVK_RightOption),
        UInt16(kVK_Shift), UInt16(kVK_RightShift),
        UInt16(kVK_Command), UInt16(kVK_RightCommand)
    ]

    init(modifierKeyCodes: [UInt16], keyCode: UInt16? = nil, keyLabel: String = "") {
        self.modifierKeyCodes = Self.modifierOrder.filter { modifierKeyCodes.contains($0) }
        self.keyCode = keyCode
        self.keyLabel = keyLabel
    }

    private enum CodingKeys: String, CodingKey {
        case modifierKeyCodes, keyCode, keyLabel, modifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let label = try container.decodeIfPresent(String.self, forKey: .keyLabel) ?? ""
        if let physical = try container.decodeIfPresent([UInt16].self, forKey: .modifierKeyCodes) {
            self.init(modifierKeyCodes: physical,
                      keyCode: try container.decodeIfPresent(UInt16.self, forKey: .keyCode),
                      keyLabel: label)
        } else {
            let legacy = try container.decode(UInt32.self, forKey: .modifiers)
            var physical: [UInt16] = []
            if legacy & UInt32(controlKey) != 0 { physical.append(UInt16(kVK_Control)) }
            if legacy & UInt32(optionKey) != 0 { physical.append(UInt16(kVK_Option)) }
            if legacy & UInt32(shiftKey) != 0 { physical.append(UInt16(kVK_Shift)) }
            if legacy & UInt32(cmdKey) != 0 { physical.append(UInt16(kVK_Command)) }
            let oldCode = try container.decode(UInt32.self, forKey: .keyCode)
            self.init(modifierKeyCodes: physical, keyCode: UInt16(oldCode), keyLabel: label)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modifierKeyCodes, forKey: .modifierKeyCodes)
        try container.encodeIfPresent(keyCode, forKey: .keyCode)
        try container.encode(keyLabel, forKey: .keyLabel)
    }

    var isValid: Bool {
        if let keyCode { return !Self.isModifier(keyCode) && !keyLabel.isEmpty }
        return !modifierKeyCodes.isEmpty
    }

    var title: String {
        let modifierNames = modifierKeyCodes.map(Self.modifierName)
        return (modifierNames + (keyCode == nil ? [] : [keyLabel])).joined(separator: " + ")
    }

    func repairingDuplicatedModifierSides() -> GlobalShortcut {
        var repaired: [UInt16] = []
        for code in modifierKeyCodes {
            guard let group = Self.modifierFlag(for: code) else { continue }
            if !repaired.contains(where: { Self.modifierFlag(for: $0) == group }) {
                repaired.append(code)
            }
        }
        return GlobalShortcut(modifierKeyCodes: repaired, keyCode: keyCode, keyLabel: keyLabel)
    }

    static func isModifier(_ code: UInt16) -> Bool { modifierOrder.contains(code) }

    static func modifierFlag(for code: UInt16) -> NSEvent.ModifierFlags? {
        switch Int(code) {
        case kVK_Command, kVK_RightCommand: .command
        case kVK_Option, kVK_RightOption: .option
        case kVK_Control, kVK_RightControl: .control
        case kVK_Shift, kVK_RightShift: .shift
        default: nil
        }
    }

    static func cgModifierFlag(for code: UInt16) -> CGEventFlags? {
        switch Int(code) {
        case kVK_Command, kVK_RightCommand: .maskCommand
        case kVK_Option, kVK_RightOption: .maskAlternate
        case kVK_Control, kVK_RightControl: .maskControl
        case kVK_Shift, kVK_RightShift: .maskShift
        default: nil
        }
    }

    static func modifierName(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_Command: "左⌘"
        case kVK_RightCommand: "右⌘"
        case kVK_Option: "左⌥"
        case kVK_RightOption: "右⌥"
        case kVK_Control: "左⌃"
        case kVK_RightControl: "右⌃"
        case kVK_Shift: "左⇧"
        case kVK_RightShift: "右⇧"
        default: "?"
        }
    }

    static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        default:
            let raw = event.charactersIgnoringModifiers ?? ""
            return raw.count == 1 ? raw.uppercased() : raw
        }
    }
}

enum HotkeySignal: Equatable {
    case press, release, toggle, armModifierHold, cancelModifierHold
}

struct ShortcutCaptureState {
    private(set) var pressedModifiers = Set<UInt16>()
    private var chordModifiers = Set<UInt16>()

    mutating func modifierChanged(code: UInt16, groupIsDown: Bool) -> GlobalShortcut? {
        guard let group = GlobalShortcut.modifierFlag(for: code) else { return nil }
        if pressedModifiers.contains(code) {
            pressedModifiers.remove(code)
        } else if groupIsDown {
            pressedModifiers.insert(code)
            chordModifiers.insert(code)
        }
        if !groupIsDown {
            pressedModifiers = pressedModifiers.filter {
                GlobalShortcut.modifierFlag(for: $0) != group
            }
        }
        guard pressedModifiers.isEmpty, !chordModifiers.isEmpty else { return nil }
        let shortcut = GlobalShortcut(modifierKeyCodes: Array(chordModifiers))
        chordModifiers.removeAll()
        return shortcut
    }

    func keyDown(code: UInt16, label: String,
                 modifierFlags: NSEvent.ModifierFlags) -> GlobalShortcut? {
        guard !GlobalShortcut.isModifier(code), !label.isEmpty else { return nil }
        let modifiers = pressedModifiers.filter {
            guard let group = GlobalShortcut.modifierFlag(for: $0) else { return false }
            return modifierFlags.contains(group)
        }
        return GlobalShortcut(modifierKeyCodes: Array(modifiers), keyCode: code, keyLabel: label)
    }

    var preview: String {
        GlobalShortcut(modifierKeyCodes: Array(chordModifiers)).title
    }
}

struct ShortcutMatcher {
    private(set) var pressedModifiers = Set<UInt16>()
    private var soloArmed = false
    private var soloUsed = false
    private var heldTrigger = false
    private(set) var holdActive = false

    mutating func reset() { self = ShortcutMatcher() }

    mutating func modifierChanged(code: UInt16, groupIsDown: Bool,
                                  shortcut: GlobalShortcut,
                                  mode: ShortcutActivationMode) -> [HotkeySignal] {
        let wasDown = pressedModifiers.contains(code)
        let isDown = !wasDown && groupIsDown
        if isDown { pressedModifiers.insert(code) }
        else { pressedModifiers.remove(code) }
        if !groupIsDown, let flag = GlobalShortcut.modifierFlag(for: code) {
            pressedModifiers = pressedModifiers.filter { GlobalShortcut.modifierFlag(for: $0) != flag }
        }

        var signals: [HotkeySignal] = []
        let matches = pressedModifiers == Set(shortcut.modifierKeyCodes)
        if shortcut.keyCode != nil {
            if heldTrigger && !matches {
                heldTrigger = false
                if holdActive { holdActive = false; signals.append(.release) }
            }
            return signals
        }

        if isDown {
            if matches && !soloUsed {
                if mode == .hold { signals.append(.armModifierHold) }
                else { soloArmed = true }
            } else if soloArmed || !Set(shortcut.modifierKeyCodes).isSuperset(of: pressedModifiers) {
                soloArmed = false
                soloUsed = true
                signals.append(.cancelModifierHold)
                if holdActive { holdActive = false; signals.append(.release) }
            }
        } else {
            signals.append(.cancelModifierHold)
            if holdActive { holdActive = false; signals.append(.release) }
            if soloArmed && !soloUsed && mode == .toggle {
                soloArmed = false
                soloUsed = true
                signals.append(.toggle)
            }
            if pressedModifiers.isEmpty { soloArmed = false; soloUsed = false }
        }
        return signals
    }

    mutating func keyChanged(code: UInt16, isDown: Bool, isRepeat: Bool,
                             shortcut: GlobalShortcut,
                             mode: ShortcutActivationMode) -> [HotkeySignal] {
        if shortcut.keyCode == nil {
            guard isDown else { return [] }
            soloArmed = false
            soloUsed = true
            var signals: [HotkeySignal] = [.cancelModifierHold]
            if holdActive { holdActive = false; signals.append(.release) }
            return signals
        }
        guard code == shortcut.keyCode else { return [] }
        if isDown {
            guard !isRepeat, !heldTrigger,
                  pressedModifiers == Set(shortcut.modifierKeyCodes) else { return [] }
            heldTrigger = true
            if mode == .hold { holdActive = true; return [.press] }
            return [.toggle]
        }
        guard heldTrigger else { return [] }
        heldTrigger = false
        if holdActive { holdActive = false; return [.release] }
        return []
    }

    mutating func activateModifierHold(shortcut: GlobalShortcut) -> [HotkeySignal] {
        guard shortcut.keyCode == nil, !soloUsed, !holdActive,
              pressedModifiers == Set(shortcut.modifierKeyCodes) else { return [] }
        holdActive = true
        return [.press]
    }
}
