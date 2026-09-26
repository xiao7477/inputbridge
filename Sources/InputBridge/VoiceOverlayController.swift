import AppKit
import SwiftUI

enum VoiceOverlayStyle {
    case local
    case remote
}

@MainActor
final class VoiceOverlayController {
    private let state = VoiceOverlayState()
    private var panel: NSPanel?

    func show(label: String = "正在听写", style: VoiceOverlayStyle = .local) {
        state.label = label
        state.style = style
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 184, height: 54),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: VoiceOverlayView(state: state))
            self.panel = panel
        }
        positionOnCurrentScreen()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func positionOnCurrentScreen() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
                ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame
        let size = panel?.frame.size ?? NSSize(width: 184, height: 54)
        panel?.setFrameOrigin(NSPoint(x: bounds.midX - size.width / 2,
                                      y: bounds.minY + 40))
    }
}

@MainActor
private final class VoiceOverlayState: ObservableObject {
    @Published var label = "正在听写"
    @Published var style: VoiceOverlayStyle = .local
}

private struct VoiceOverlayView: View {
    @ObservedObject var state: VoiceOverlayState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(state.style == .remote ? Color.yellow : Color.white)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(0..<7) { index in
                        Capsule()
                            .fill(Color.white.opacity(0.95))
                            .frame(width: 1.5,
                                   height: 6 + 18 * abs(sin(time * 5 + Double(index) * 0.72)))
                    }
                }
                .frame(height: 28)
            }
            Text(state.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(width: 184, height: 46)
        .background(Color.black, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .frame(width: 184, height: 54)
    }
}
