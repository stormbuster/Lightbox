//
//  WindowChrome.swift
//  Lightbox
//
//  Borderless styling for a SwiftUI window (as in stormbuster/borderless): no title bar, draggable from anywhere,
//  and only the chosen traffic-light buttons, which fade in while the cursor is over the window.
//

import SwiftUI
import AppKit


struct WindowChrome: NSViewRepresentable {
    var buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton]
    var floating = false
    /// Transparent window for content that draws a Liquid Glass background (`.glassEffect`).
    var glass = false

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.buttons = buttons
        view.floating = floating
        view.glass = glass
        return view
    }

    func updateNSView(_ nsView: ChromeView, context: Context) {}

    final class ChromeView: NSView {
        var buttons: [NSWindow.ButtonType] = []
        var floating = false
        var glass = false
        private var hover: WindowButtonHover?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            if glass {
                // Content draws its own Liquid Glass; the window itself must be see-through.
                window.isOpaque = false
                window.backgroundColor = .clear
            }
            if floating {
                window.level = .floating
                window.hidesOnDeactivate = true
            }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] where !buttons.contains(type) {
                window.standardWindowButton(type)?.isHidden = true
            }
            hover = WindowButtonHover(window: window, buttons: buttons)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { hover?.cursorEntered() }
        override func mouseExited(with event: NSEvent) { hover?.cursorExited() }
    }
}


/// Shows a window's traffic-light buttons while the cursor is over the window. Hover is judged against the whole
/// window frame rather than the content view's tracking area: the buttons sit in the title bar above the content, so
/// moving onto them would otherwise count as leaving and hide them under the cursor. While they are shown, a light
/// poll catches the cursor leaving by way of the title bar, where the content view gets no exit event.
@MainActor
final class WindowButtonHover {
    private weak var window: NSWindow?
    private let buttons: [NSWindow.ButtonType]
    private var poll: Timer?
    private var shown = true

    init(window: NSWindow, buttons: [NSWindow.ButtonType]) {
        self.window = window
        self.buttons = buttons
        set(false, animated: false)
    }

    func cursorEntered() {
        set(true, animated: true)
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func cursorExited() { check() }

    private func check() {
        guard let window, !window.frame.contains(NSEvent.mouseLocation) else { return }
        poll?.invalidate()
        poll = nil
        set(false, animated: true)
    }

    private func set(_ show: Bool, animated: Bool) {
        guard let window, show != shown else { return }
        shown = show
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.18 : 0
            for type in buttons {
                guard let button = window.standardWindowButton(type) else { continue }
                button.isHidden = false
                button.animator().alphaValue = show ? 1 : 0
            }
        }
    }
}


/// The system's Liquid Glass material as a window background (AppKit's NSGlassEffectView).
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = 22
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {}
}
