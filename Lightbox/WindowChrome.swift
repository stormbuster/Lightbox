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
            show(false, animated: false)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { show(true, animated: true) }
        override func mouseExited(with event: NSEvent) { show(false, animated: true) }

        private func show(_ visible: Bool, animated: Bool) {
            guard let window else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? 0.18 : 0
                for type in buttons { window.standardWindowButton(type)?.animator().alphaValue = visible ? 1 : 0 }
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
