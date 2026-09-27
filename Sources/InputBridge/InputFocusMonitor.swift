import AppKit
import ApplicationServices

/// An active dictation belongs to the editor (or Screen Sharing window) that started it.
/// AX checks run off the main thread so an unresponsive target cannot stall the hotkey tap.
struct InputFocusTarget: @unchecked Sendable {
    enum Kind { case editor, window, application }

    let applicationPID: pid_t
    private let element: AXUIElement?
    private let window: AXUIElement?
    private let kind: Kind

    static func editor(applicationPID: pid_t, element: AXUIElement) -> Self {
        let app = AXUIElementCreateApplication(applicationPID)
        AXUIElementSetMessagingTimeout(app, 0.2)
        return Self(applicationPID: applicationPID, element: element,
                    window: attribute(kAXFocusedWindowAttribute as CFString, from: app),
                    kind: .editor)
    }

    @MainActor
    static func frontmostWindow() -> Self? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        if let window = attribute(kAXFocusedWindowAttribute as CFString, from: app) {
            return Self(applicationPID: pid, element: window, window: window, kind: .window)
        }
        return Self(applicationPID: pid, element: nil, window: nil, kind: .application)
    }

    func isFocused() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let activeApp = Self.attribute(kAXFocusedApplicationAttribute as CFString,
                                             from: system),
              Self.pid(of: activeApp) == applicationPID else { return false }
        guard let element else { return true }
        let app = AXUIElementCreateApplication(applicationPID)
        AXUIElementSetMessagingTimeout(app, 0.2)
        switch kind {
        case .application:
            return true
        case .window:
            return Self.attribute(kAXFocusedWindowAttribute as CFString, from: app)
                .map { CFEqual($0, element) } ?? false
        case .editor:
            if let window {
                guard let currentWindow = Self.attribute(kAXFocusedWindowAttribute as CFString,
                                                          from: app),
                      CFEqual(currentWindow, window) else { return false }
            }
            // Electron may report the editor on the app or the system-wide element.
            let appFocus = Self.attribute(kAXFocusedUIElementAttribute as CFString, from: app)
            if let appFocus, CFEqual(appFocus, element) { return true }
            let systemFocus = Self.attribute(kAXFocusedUIElementAttribute as CFString,
                                             from: system)
            return systemFocus.map { CFEqual($0, element) } ?? false
        }
    }

    private static func attribute(_ name: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }
}

@MainActor
final class InputFocusMonitor {
    private var task: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var generation = UUID()

    func start(target: InputFocusTarget, onLost: @escaping @MainActor () -> Void) {
        stop()
        let currentGeneration = generation
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                if app?.processIdentifier != target.applicationPID {
                    self?.reportLoss(generation: currentGeneration, onLost: onLost)
                }
            }
        }
        task = Task.detached(priority: .utility) { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                misses = target.isFocused() ? 0 : misses + 1
                if misses >= 2 {
                    await self?.reportLoss(generation: currentGeneration, onLost: onLost)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    private func reportLoss(generation: UUID, onLost: @MainActor () -> Void) {
        guard self.generation == generation else { return }
        stop()
        onLost()
    }
}
