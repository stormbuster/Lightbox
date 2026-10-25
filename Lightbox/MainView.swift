//
//  MainView.swift
//  Lightbox
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers


struct MainView: View {
    let window: NSWindow?
    @Environment(Editor.self) private var editor
    @Environment(\.openWindow) private var openWindow
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            Color.black

            if let preview = editor.displayedPreview {
                ZStack {
                    if editor.layer?.mask != nil && !editor.showOriginal { Checkerboard() }
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                }
                .aspectRatio(CGFloat(preview.width) / CGFloat(preview.height), contentMode: .fit)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48, weight: .thin))
                    Text("Drop a photo anywhere")
                        .font(.title3)
                    Text("JPEG, HEIC, TIFF, PNG or RAW · ⌘O to browse")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white.opacity(0.7))
            }

            if editor.isBusy {
                BusyBadge(status: editor.status, progress: editor.progress)
            }

            if isTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 4)
                    .background(Color.accentColor.opacity(0.08))
                    .padding(6)
            }
        }
        .edgesIgnoringSafeArea(.all)
        .overlay(DropDragView.Representable(isTargeted: $isTargeted) { urls in
            editor.load(urls.first!)
        })
        .onChange(of: editor.documentID) {
            guard let layer = editor.layer else { return }
            fit(window, to: CGSize(width: layer.rgb.width, height: layer.rgb.height))
            openWindow(id: "tools")
        }
        .alert("Lightbox", isPresented: Binding(get: { editor.errorMessage != nil },
                                                set: { if !$0 { editor.errorMessage = nil } })) {
            Button("OK") { editor.errorMessage = nil }
        } message: {
            Text(editor.errorMessage ?? "")
        }
    }

    /// Give the borderless window the photo's aspect ratio, as large as fits on screen.
    private func fit(_ window: NSWindow?, to size: CGSize) {
        guard let window, let screen = window.screen ?? NSScreen.main, size.width > 0, size.height > 0 else { return }
        let area = screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.08, dy: screen.visibleFrame.height * 0.08)
        let scale = min(area.width / size.width, area.height / size.height)
        let content = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        window.contentAspectRatio = size
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: content))
        frame.origin = CGPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
        window.setFrame(frame, display: true, animate: true)
    }
}


/// Transparent AppKit layer over the whole window: drags the window on mouse down (as in Borderless)
/// and accepts dropped photos from Finder, Photos (file promises) or any app offering image data.
final class DropDragView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onTargeted: ((Bool) -> Void)?

    private static let imageTypes = [UTType.image.identifier]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .tiff, .png] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = canRead(sender.draggingPasteboard)
        onTargeted?(ok)
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: Self.imageTypes]) as? [URL], !urls.isEmpty {
            onDrop?(urls)
            return true
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           let promise = promises.first {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Drops/\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            promise.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { [weak self] url, error in
                guard error == nil else { return }
                MainActor.assumeIsolated { self?.onDrop?([url]) }
            }
            return true
        }
        if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Dropped \(UUID().uuidString.prefix(8)).tiff")
            if (try? tiff.write(to: url)) != nil { onDrop?([url]); return true }
        }
        return false
    }

    private func canRead(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: Self.imageTypes])
        || pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        || NSImage.canInit(with: pb)
    }

    struct Representable: NSViewRepresentable {
        @Binding var isTargeted: Bool
        let onDrop: ([URL]) -> Void

        func makeNSView(context: Context) -> DropDragView {
            let view = DropDragView()
            view.onDrop = onDrop
            view.onTargeted = { isTargeted = $0 }
            return view
        }

        func updateNSView(_ nsView: DropDragView, context: Context) {
            nsView.onDrop = onDrop
        }
    }
}


struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 12
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.85)))
            for row in 0..<Int(ceil(size.height / cell)) {
                for col in 0..<Int(ceil(size.width / cell)) where (row + col).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(Color(white: 0.65)))
                }
            }
        }
    }
}


struct BusyBadge: View {
    let status: String
    let progress: Double?

    var body: some View {
        VStack(spacing: 10) {
            if let progress {
                ProgressView(value: progress).frame(width: 220)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(status).font(.callout).monospacedDigit()
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
