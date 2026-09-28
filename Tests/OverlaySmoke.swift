import AppKit
import Foundation

@main
struct OverlaySmoke {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let previousApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let overlay = VoiceOverlayController()
        overlay.show()
        precondition(previousApp == NSWorkspace.shared.frontmostApplication?.processIdentifier)
        // Wake the run loop even though layer animation needs no app-side timer.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in }
        defer { timer.invalidate() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let currentApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        precondition(currentApp != ProcessInfo.processInfo.processIdentifier)
        precondition(!app.windows.contains { $0.isKeyWindow || $0.isMainWindow })
        overlay.hide()
        print("PASS: 底部浮层显示时未抢走前台 App 焦点")
    }
}
