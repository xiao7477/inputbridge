import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalHotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: ((TimeInterval?) -> Void)?
    var onToggle: ((TimeInterval?) -> Void)?
    var onCancel: (() -> Bool)?
    var onCapture: ((GlobalShortcut?) -> Void)?
    var onMonitorFailure: ((String) -> Void)?

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapOptions: CGEventTapOptions?
    private var shortcut: GlobalShortcut = .defaultShortcut
    private var mode: ShortcutActivationMode = .hold
    private var matcher = ShortcutMatcher()
    private var captureState = ShortcutCaptureState()
    private var pendingHold: Task<Void, Never>?
    private var capturing = false
    private var interceptingDictation = false
    private var captureStartedAt: Date?
    private var tapTimeouts: [Date] = []
    private var consumingKey = false
    private var suppressUntilModifiersReleased = false
    private var compatibilityTimer: Timer?
    private var compatibilityWasDown = false
    private var compatibilityTriggered = false
    private var compatibilityNativeHandled = false
    private var compatibilityDownSince: Date?
    private var escapeWasDown = false
    private var consumingEscape = false
    private var enabled = true

    func register(_ newShortcut: GlobalShortcut) throws {
        guard newShortcut.isValid else {
            throw BridgeError.transport("请设置一个按键或按键组合。")
        }
        let previousShortcut = shortcut
        shortcut = newShortcut
        do {
            try ensureTap(options: preferredTapOptions)
        } catch {
            shortcut = previousShortcut
            throw error
        }
        tapTimeouts.removeAll()
        resetTrigger()
        resetCompatibilityState()
    }

    func setActivationMode(_ newMode: ShortcutActivationMode) {
        resetTrigger()
        mode = newMode
    }

    func setInterceptionActive(_ active: Bool) {
        guard interceptingDictation != active else { return }
        interceptingDictation = active
        do { try ensureTap(options: preferredTapOptions) }
        catch { onMonitorFailure?(error.localizedDescription) }
    }

    func setEnabled(_ newValue: Bool) {
        guard enabled != newValue else { return }
        resetTrigger()
        resetCompatibilityState()
        capturing = false
        captureStartedAt = nil
        enabled = newValue
        if let tap { CGEvent.tapEnable(tap: tap, enable: newValue) }
    }

    func beginCapture() throws {
        try ensureTap(options: .defaultTap)
        resetTrigger()
        resetCompatibilityState()
        captureState = ShortcutCaptureState()
        capturing = true
        captureStartedAt = Date()
        tapTimeouts.removeAll()
    }

    func endCapture(suppressUntilRelease: Bool = false) {
        resetTrigger()
        resetCompatibilityState()
        capturing = false
        captureStartedAt = nil
        suppressUntilModifiersReleased = suppressUntilRelease
        do { try ensureTap(options: preferredTapOptions) }
        catch { onMonitorFailure?(error.localizedDescription) }
    }

    private var preferredTapOptions: CGEventTapOptions {
        // A modifier-only shortcut has no character key to suppress. A passive tap
        // observes it without taking ownership of keyboard events from other apps.
        shortcut.keyCode == nil && !interceptingDictation ? .listenOnly : .defaultTap
    }

    private func ensureTap(options: CGEventTapOptions) throws {
        if let tap, tapOptions == options {
            if enabled, !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard TextInjector.hasPermission else {
            throw BridgeError.permission("全局快捷键需要辅助功能权限。请授权当前“语音输入共享”App 后重新启动。")
        }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    manager.handle(type: type, event: event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            throw BridgeError.permission("无法启用全局快捷键监听。请检查辅助功能权限并重新启动 App。")
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = newTap
        tapSource = source
        tapOptions = options
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: enabled)
        startCompatibilityTimer()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            let now = Date()
            tapTimeouts.removeAll { now.timeIntervalSince($0) > 30 }
            tapTimeouts.append(now)
            if tapTimeouts.count >= 3 {
                onMonitorFailure?("快捷键监听多次超时，已暂停以恢复系统键盘输入。请重新设置快捷键或重启 App。")
            } else {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, self.enabled, self.tapTimeouts.count < 3,
                          let tap = self.tap else { return }
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != InputBridgeEventMarker.keyboardInjection
        else { return Unmanaged.passUnretained(event) }
        guard enabled else { return Unmanaged.passUnretained(event) }

        if capturing {
            if let captureStartedAt, Date().timeIntervalSince(captureStartedAt) > 15 {
                onCapture?(nil)
                return Unmanaged.passUnretained(event)
            }
            return capture(type: type, event: event)
        }

        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if (type == .keyDown || type == .keyUp), code == UInt16(kVK_Escape) {
            return handleEscape(type: type, event: event)
        }

        if suppressUntilModifiersReleased {
            if type == .flagsChanged,
               event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty {
                suppressUntilModifiersReleased = false
                matcher.reset()
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            if let group = GlobalShortcut.cgModifierFlag(for: code) {
                let signals = matcher.modifierChanged(code: code,
                                                      groupIsDown: event.flags.contains(group),
                                                      shortcut: shortcut, mode: mode)
                if shortcut.keyCode == nil,
                   matcher.pressedModifiers == Set(shortcut.modifierKeyCodes) {
                    compatibilityNativeHandled = true
                }
                markNativeTriggerIfNeeded(signals)
                act(on: signals, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }

        if shortcut.keyCode == nil {
            if type == .keyDown {
                act(on: matcher.keyChanged(code: code, isDown: true,
                                           isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                           shortcut: shortcut, mode: mode), event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard code == shortcut.keyCode else { return Unmanaged.passUnretained(event) }
        if type == .keyDown {
            if consumingKey { return nil }
            let signals = matcher.keyChanged(code: code, isDown: true,
                                             isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                             shortcut: shortcut, mode: mode)
            guard !signals.isEmpty else { return Unmanaged.passUnretained(event) }
            consumingKey = true
            markNativeTriggerIfNeeded(signals)
            act(on: signals, event: event)
            return nil
        }
        let wasConsuming = consumingKey
        consumingKey = false
        act(on: matcher.keyChanged(code: code, isDown: false, isRepeat: false,
                                   shortcut: shortcut, mode: mode), event: event)
        return wasConsuming ? nil : Unmanaged.passUnretained(event)
    }

    private func capture(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .flagsChanged {
            if let group = GlobalShortcut.cgModifierFlag(for: code),
               let captured = captureState.modifierChanged(code: code,
                                                           groupIsDown: event.flags.contains(group)) {
                onCapture?(captured)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
        if code == UInt16(kVK_Escape) { onCapture?(nil); return nil }
        let label = NSEvent(cgEvent: event).map(GlobalShortcut.keyName) ?? ""
        if let captured = captureState.keyDown(code: code, label: label,
                                                modifierFlags: modifierFlags(from: event.flags)) {
            onCapture?(captured)
        } else {
            NSSound.beep()
        }
        return nil
    }

    private func modifierFlags(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }

    private func resetTrigger() {
        if matcher.holdActive { onRelease?(nil) }
        matcher.reset()
        consumingKey = false
        pendingHold?.cancel()
        pendingHold = nil
    }

    private func startCompatibilityTimer() {
        guard compatibilityTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCompatibilityShortcut() }
        }
        RunLoop.main.add(timer, forMode: .common)
        compatibilityTimer = timer
    }

    private func checkCompatibilityShortcut() {
        guard enabled else { return }
        checkCompatibilityEscape()
        guard !capturing else { return }
        let isDown = isShortcutPhysicallyDown()
        if !isDown {
            if compatibilityTriggered, mode == .hold { onRelease?(nil) }
            resetCompatibilityState()
            return
        }
        if !compatibilityWasDown {
            compatibilityWasDown = true
            compatibilityDownSince = Date()
        }
        guard !compatibilityTriggered, !compatibilityNativeHandled,
              let compatibilityDownSince else { return }
        let delay = shortcut.keyCode == nil ? 0.22 : 0.045
        guard Date().timeIntervalSince(compatibilityDownSince) >= delay else { return }
        compatibilityTriggered = true
        if mode == .hold { onPress?() }
        else { onToggle?(nil) }
    }

    private func handleEscape(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            if !escapeWasDown {
                escapeWasDown = true
                consumingEscape = onCancel?() ?? false
            }
            return consumingEscape ? nil : Unmanaged.passUnretained(event)
        }
        let shouldConsume = consumingEscape
        escapeWasDown = false
        consumingEscape = false
        return shouldConsume ? nil : Unmanaged.passUnretained(event)
    }

    private func checkCompatibilityEscape() {
        guard !capturing else { return }
        let isDown = CGEventSource.keyState(.combinedSessionState,
                                            key: CGKeyCode(kVK_Escape))
        if isDown, !escapeWasDown {
            escapeWasDown = true
            consumingEscape = onCancel?() ?? false
        } else if !isDown {
            escapeWasDown = false
            consumingEscape = false
        }
    }

    private func isShortcutPhysicallyDown() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let allGroups: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        var required: CGEventFlags = []
        for code in shortcut.modifierKeyCodes {
            if let flag = GlobalShortcut.cgModifierFlag(for: code) { required.insert(flag) }
        }
        guard flags.intersection(allGroups) == required else { return false }
        if let keyCode = shortcut.keyCode {
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
        }
        guard !required.isEmpty else { return false }
        return !(0..<128).contains { rawCode in
            let code = UInt16(rawCode)
            return !GlobalShortcut.isModifier(code) &&
                CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        }
    }

    private func markNativeTriggerIfNeeded(_ signals: [HotkeySignal]) {
        if signals.contains(where: { signal in
            switch signal {
            case .press, .toggle, .armModifierHold: true
            case .release, .cancelModifierHold: false
            }
        }) {
            compatibilityNativeHandled = true
        }
    }

    private func resetCompatibilityState() {
        compatibilityWasDown = false
        compatibilityTriggered = false
        compatibilityNativeHandled = false
        compatibilityDownSince = nil
    }

    private func act(on signals: [HotkeySignal], event: CGEvent? = nil) {
        for signal in signals {
            switch signal {
            case .press: onPress?()
            case .release: onRelease?(eventTimestamp(event))
            case .toggle: onToggle?(eventTimestamp(event))
            case .cancelModifierHold:
                pendingHold?.cancel()
                pendingHold = nil
            case .armModifierHold:
                pendingHold?.cancel()
                pendingHold = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.act(on: self.matcher.activateModifierHold(shortcut: self.shortcut))
                    self.pendingHold = nil
                }
            }
        }
    }

    private func eventTimestamp(_ event: CGEvent?) -> TimeInterval? {
        guard let event, let timestamp = NSEvent(cgEvent: event)?.timestamp else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        guard timestamp > 0, timestamp <= now, now - timestamp < 60 else { return nil }
        return timestamp
    }

    deinit {
        compatibilityTimer?.invalidate()
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        pendingHold?.cancel()
    }
}
