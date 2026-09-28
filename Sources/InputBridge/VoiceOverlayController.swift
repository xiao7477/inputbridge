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

    func show(label: String = "正在听写", style: VoiceOverlayStyle = .local,
              animate: Bool = true) {
        if state.label != label { state.label = label }
        if state.style != style { state.style = style }
        if state.isAnimating != animate { state.isAnimating = animate }
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

    func hide() {
        state.isAnimating = false
        panel?.orderOut(nil)
    }

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
    @Published var isAnimating = false
}

private struct VoiceOverlayView: View {
    @ObservedObject var state: VoiceOverlayState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(state.style == .remote ? Color.yellow : Color.white)
            WaveformBars(animating: state.isAnimating)
                .frame(width: 25, height: 28)
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

/// Core Animation changes only layer transforms; no SwiftUI layout on each frame.
private struct WaveformBars: NSViewRepresentable {
    var animating: Bool

    func makeNSView(context: Context) -> WaveformBarView { WaveformBarView() }
    func updateNSView(_ view: WaveformBarView, context: Context) {
        view.setAnimating(animating)
    }
    static func dismantleNSView(_ view: WaveformBarView, coordinator: ()) {
        view.setAnimating(false)
    }
}

private final class WaveformBarView: NSView {
    private var bars: [CALayer] = []
    private var animating = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 25, height: 28))
        wantsLayer = true
        for index in 0..<7 {
            let bar = CALayer()
            bar.bounds = CGRect(x: 0, y: 0, width: 1.5, height: 24)
            bar.position = CGPoint(x: 0.75 + Double(index) * 4, y: 14)
            bar.cornerRadius = 0.75
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
            bar.isHidden = true
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }
    required init?(coder: NSCoder) { nil }

    func setAnimating(_ active: Bool) {
        guard active != animating else { return }
        animating = active
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.isHidden = !active
            bar.removeAllAnimations()
            if active {
                let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
                animation.values = [0.25, 1, 0.4, 0.8, 0.25]
                animation.duration = 1.1
                animation.timeOffset = Double(index) * 0.13
                animation.repeatCount = .infinity
                animation.calculationMode = .linear
                bar.add(animation, forKey: "waveform")
            }
        }
        CATransaction.commit()
    }
}
