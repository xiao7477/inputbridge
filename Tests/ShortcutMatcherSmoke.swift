import AppKit
import Carbon.HIToolbox
import Foundation

@main
struct ShortcutMatcherSmoke {
    static func main() throws {
        let leftCommand = UInt16(kVK_Command)
        let rightCommand = UInt16(kVK_RightCommand)
        let rightOption = UInt16(kVK_RightOption)
        let leftOnly = GlobalShortcut(modifierKeyCodes: [leftCommand])
        var matcher = ShortcutMatcher()

        precondition(!matcher.modifierChanged(code: rightCommand, groupIsDown: true,
                                              shortcut: leftOnly, mode: .hold).contains(.armModifierHold))
        precondition(matcher.modifierChanged(code: rightCommand, groupIsDown: false,
                                             shortcut: leftOnly, mode: .hold).contains(.cancelModifierHold))
        precondition(matcher.modifierChanged(code: leftCommand, groupIsDown: true,
                                             shortcut: leftOnly, mode: .hold) == [.armModifierHold])
        precondition(matcher.activateModifierHold(shortcut: leftOnly) == [.press])
        precondition(matcher.modifierChanged(code: leftCommand, groupIsDown: false,
                                             shortcut: leftOnly, mode: .hold) == [.cancelModifierHold, .release])

        matcher.reset()
        _ = matcher.modifierChanged(code: leftCommand, groupIsDown: true,
                                    shortcut: leftOnly, mode: .toggle)
        precondition(matcher.modifierChanged(code: leftCommand, groupIsDown: false,
                                             shortcut: leftOnly, mode: .toggle).contains(.toggle))

        matcher.reset()
        _ = matcher.modifierChanged(code: leftCommand, groupIsDown: true,
                                    shortcut: leftOnly, mode: .toggle)
        _ = matcher.keyChanged(code: UInt16(kVK_ANSI_C), isDown: true, isRepeat: false,
                                shortcut: leftOnly, mode: .toggle)
        precondition(!matcher.modifierChanged(code: leftCommand, groupIsDown: false,
                                              shortcut: leftOnly, mode: .toggle).contains(.toggle))

        let bothSides = GlobalShortcut(modifierKeyCodes: [leftCommand, rightOption])
        matcher.reset()
        precondition(matcher.modifierChanged(code: leftCommand, groupIsDown: true,
                                             shortcut: bothSides, mode: .toggle).isEmpty)
        precondition(matcher.modifierChanged(code: rightOption, groupIsDown: true,
                                             shortcut: bothSides, mode: .toggle).isEmpty)
        precondition(matcher.modifierChanged(code: rightOption, groupIsDown: false,
                                             shortcut: bothSides, mode: .toggle).contains(.toggle))

        matcher.reset()
        let defaultShortcut = GlobalShortcut.defaultShortcut
        _ = matcher.modifierChanged(code: UInt16(kVK_Option), groupIsDown: true,
                                    shortcut: defaultShortcut, mode: .hold)
        precondition(matcher.keyChanged(code: UInt16(kVK_Space), isDown: true, isRepeat: false,
                                         shortcut: defaultShortcut, mode: .hold) == [.press])
        precondition(matcher.keyChanged(code: UInt16(kVK_Space), isDown: true, isRepeat: true,
                                         shortcut: defaultShortcut, mode: .hold).isEmpty)
        precondition(matcher.keyChanged(code: UInt16(kVK_Space), isDown: false, isRepeat: false,
                                         shortcut: defaultShortcut, mode: .hold) == [.release])

        let commandQuote = GlobalShortcut(modifierKeyCodes: [leftCommand],
                                          keyCode: UInt16(kVK_ANSI_Quote), keyLabel: "'")
        matcher.reset()
        _ = matcher.modifierChanged(code: rightCommand, groupIsDown: true,
                                    shortcut: commandQuote, mode: .toggle)
        precondition(matcher.keyChanged(code: UInt16(kVK_ANSI_Quote), isDown: true,
                                         isRepeat: false, shortcut: commandQuote,
                                         mode: .toggle).isEmpty)
        _ = matcher.modifierChanged(code: rightCommand, groupIsDown: false,
                                    shortcut: commandQuote, mode: .toggle)
        _ = matcher.modifierChanged(code: leftCommand, groupIsDown: true,
                                    shortcut: commandQuote, mode: .toggle)
        precondition(matcher.keyChanged(code: UInt16(kVK_ANSI_Quote), isDown: true,
                                         isRepeat: false, shortcut: commandQuote,
                                         mode: .toggle) == [.toggle])
        precondition(matcher.keyChanged(code: UInt16(kVK_ANSI_Quote), isDown: false,
                                         isRepeat: false, shortcut: commandQuote,
                                         mode: .toggle).isEmpty)
        precondition(GlobalShortcut.cgModifierFlag(for: leftCommand) == .maskCommand)

        let legacy = Data("{\"keyCode\":49,\"modifiers\":2048,\"keyLabel\":\"Space\"}".utf8)
        let migrated = try JSONDecoder().decode(GlobalShortcut.self, from: legacy)
        precondition(migrated.modifierKeyCodes == [UInt16(kVK_Option)])
        precondition(migrated.keyCode == UInt16(kVK_Space))
        let singleKey = GlobalShortcut(modifierKeyCodes: [],
                                       keyCode: UInt16(kVK_F18), keyLabel: "F18")
        precondition(singleKey.isValid && singleKey.title == "F18")
        var capture = ShortcutCaptureState()
        precondition(capture.modifierChanged(code: rightCommand, groupIsDown: true) == nil)
        let commandKey = capture.keyDown(code: UInt16(kVK_ANSI_K), label: "K",
                                         modifierFlags: .command)
        precondition(commandKey?.modifierKeyCodes == [rightCommand])
        precondition(commandKey?.keyCode == UInt16(kVK_ANSI_K))
        capture = ShortcutCaptureState()
        precondition(capture.modifierChanged(code: leftCommand, groupIsDown: true) == nil)
        let noDuplicatedSides = capture.keyDown(code: UInt16(kVK_ANSI_Quote), label: "'",
                                                modifierFlags: .command)
        precondition(noDuplicatedSides?.modifierKeyCodes == [leftCommand])
        let accidentallyDuplicated = GlobalShortcut(
            modifierKeyCodes: [UInt16(kVK_Shift), UInt16(kVK_RightShift),
                               leftCommand, rightCommand],
            keyCode: UInt16(kVK_ANSI_Backslash), keyLabel: "|")
        precondition(accidentallyDuplicated.repairingDuplicatedModifierSides().modifierKeyCodes == [
            UInt16(kVK_Shift), leftCommand
        ])
        capture = ShortcutCaptureState()
        precondition(capture.modifierChanged(code: rightCommand, groupIsDown: true) == nil)
        precondition(capture.modifierChanged(code: rightCommand, groupIsDown: false)?.modifierKeyCodes == [rightCommand])
        capture = ShortcutCaptureState()
        precondition(capture.modifierChanged(code: leftCommand, groupIsDown: true) == nil)
        precondition(capture.modifierChanged(code: rightOption, groupIsDown: true) == nil)
        precondition(capture.modifierChanged(code: leftCommand, groupIsDown: false) == nil)
        let modifierChord = capture.modifierChanged(code: rightOption, groupIsDown: false)
        precondition(modifierChord?.modifierKeyCodes == [rightOption, leftCommand])
        print("PASS: 左右修饰键、单键/组合键、按住/切换及旧设置迁移")
    }
}
