import AppKit
import Foundation

@main
struct OverlaySmoke {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let previousApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let overlay = VoiceOverlayController()
        overlay.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let currentApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        overlay.hide()
        precondition(previousApp == currentApp)
        print("PASS: 底部浮层显示时未抢走前台 App 焦点")
    }
}
