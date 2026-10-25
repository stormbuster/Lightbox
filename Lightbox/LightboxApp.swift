//
//  LightboxApp.swift
//  Lightbox
//
//  Borderless photo window (from stormbuster/borderless) with a floating tools panel.
//

import SwiftUI
import AppKit


struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.window = view.window   // << right after inserted in window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}


/// Photos opened from Finder ("Open With", or dropped on the Dock icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var editor: Editor?
    private var pending: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let editor { editor.load(url) } else { pending = url }
    }

    func attach(_ editor: Editor) {
        self.editor = editor
        #if DEBUG
        SelfTest.editor = editor
        #endif
        if let pending { editor.load(pending); self.pending = nil }
    }
}


@main
struct LightboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var editor = Editor()
    @State private var window: NSWindow?

    init() {
        #if DEBUG
        SelfTest.runIfRequested()
        #endif
    }

    var body: some Scene {
        Window("Lightbox", id: "main") {
            MainView(window: window)
                .environment(editor)
                .background(WindowAccessor(window: $window))
                .onChange(of: window) { _, newWindow in
                    guard let newWindow else { return }
                    newWindow.styleMask.update(with: .fullSizeContentView) // Exclude title bar from content area
                    newWindow.titlebarAppearsTransparent = true
                    newWindow.backgroundColor = .black
                    newWindow.contentAspectRatio = CGSize(width: 16, height: 9)
                    DropDragView.setWindowButtons(of: newWindow, visible: false, animated: false)
                }
                .task { await Engine.shared.warmUp() }
                .onAppear { appDelegate.attach(editor) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { editor.openWithPanel() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save As…") { editor.saveWithPanel() }.keyboardShortcut("s")
                    .disabled(editor.layer == nil || editor.isBusy)
            }
            CommandMenu("Compare") {
                Button(editor.showOriginal ? "Show Edited" : "Show Original") { editor.showOriginal.toggle() }
                    .keyboardShortcut("\\", modifiers: [])
                    .disabled(!editor.isModified)
                Button(editor.splitCompare ? "Hide Before/After Split" : "Before/After Split") { editor.splitCompare.toggle() }
                    .keyboardShortcut("\\", modifiers: .command)
                    .disabled(!editor.isModified)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { editor.undo() }.keyboardShortcut("z")
                    .disabled(!editor.canUndo || editor.isBusy)
            }
        }

        UtilityWindow("Tools", id: "tools") {
            ToolsPanel()
                .environment(editor)
        }
        .defaultWindowPlacement { _, context in
            let screen = context.defaultDisplay.visibleRect
            return WindowPlacement(CGPoint(x: screen.maxX - 340, y: screen.minY + 80))
        }
    }
}
