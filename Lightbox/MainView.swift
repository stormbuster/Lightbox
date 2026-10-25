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

    private var isSplit: Bool { editor.splitCompare && !editor.showOriginal && editor.isModified }

    var body: some View {
        ZStack {
            Color.black

            if editor.isZoomed, let layer = editor.layer {
                ActualPixels(after: layer.full, before: editor.original?.full, center: editor.zoomCenter,
                             showBefore: editor.showOriginal, split: isSplit ? editor.splitPosition : nil,
                             hasAlpha: layer.mask != nil,
                             backdrop: editor.backdrop == .color ? NSColor(editor.backdropColor) : nil)
            } else if let preview = editor.displayedPreview {
                ZStack {
                    if editor.layer?.mask != nil && !editor.showOriginal {
                        if editor.backdrop == .color { editor.backdropColor } else { Checkerboard() }
                    }
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                    if isSplit, let original = editor.original?.preview {
                        // Before on the left of the split line, after on the right.
                        Image(decorative: original, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .mask {
                                GeometryReader { geo in
                                    Rectangle().frame(width: geo.size.width * editor.splitPosition)
                                }
                            }
                    }
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
        .overlay(DropDragView.Representable(isTargeted: $isTargeted, onDrop: { urls in
            editor.load(urls.first!)
        }, onDoubleClick: { point, viewSize in
            editor.toggleZoom(at: imagePoint(point, in: viewSize))
        }, onPan: { delta in
            editor.pan(by: delta)
        }, isZoomed: { editor.isZoomed }))
        .overlay {
            // Above the window-drag layer so the handle receives the drag.
            if isSplit, let preview = editor.displayedPreview {
                SplitHandle(position: Bindable(editor).splitPosition,
                            aspect: editor.isZoomed ? nil : CGFloat(preview.width) / CGFloat(preview.height))
            }
        }
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

    /// A point in the window (top-left origin) as image pixels of the displayed layer, for zooming in on it.
    private func imagePoint(_ point: CGPoint, in viewSize: CGSize) -> CGPoint? {
        guard let size = editor.layer?.pixelSize, size.width > 0, size.height > 0 else { return nil }
        let scale = min(viewSize.width / size.width, viewSize.height / size.height)
        let origin = CGPoint(x: (viewSize.width - size.width * scale) / 2, y: (viewSize.height - size.height * scale) / 2)
        return CGPoint(x: min(max((point.x - origin.x) / scale, 0), size.width),
                       y: min(max((point.y - origin.y) / scale, 0), size.height))
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
    /// Double-click location (top-left origin, points) and the view size.
    var onDoubleClick: ((CGPoint, CGSize) -> Void)?
    /// Pan by a distance in image pixels (at 100 %).
    var onPan: ((CGPoint) -> Void)?
    var isZoomed: () -> Bool = { false }

    private static let imageTypes = [UTType.image.identifier]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .tiff, .png] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let p = convert(event.locationInWindow, from: nil)
            onDoubleClick?(CGPoint(x: p.x, y: bounds.height - p.y), bounds.size)
        } else if !isZoomed() {
            window?.performDrag(with: event)   // at 100 % a drag pans instead (mouseDragged)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isZoomed() else { return }
        let scale = window?.backingScaleFactor ?? 2
        onPan?(CGPoint(x: event.deltaX * scale, y: event.deltaY * scale))
    }

    override func scrollWheel(with event: NSEvent) {
        guard isZoomed() else { return super.scrollWheel(with: event) }
        let scale = (window?.backingScaleFactor ?? 2) * (event.hasPreciseScrollingDeltas ? 1 : 10)
        onPan?(CGPoint(x: event.scrollingDeltaX * scale, y: event.scrollingDeltaY * scale))
    }

    // The traffic-light buttons stay out of the way and fade in while the cursor is over the window.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private var hover: WindowButtonHover?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        hover = WindowButtonHover(window: window, buttons: [.closeButton, .miniaturizeButton, .zoomButton])
    }

    override func mouseEntered(with event: NSEvent) { hover?.cursorEntered() }
    override func mouseExited(with event: NSEvent) { hover?.cursorExited() }

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
        let onDoubleClick: (CGPoint, CGSize) -> Void
        let onPan: (CGPoint) -> Void
        let isZoomed: () -> Bool

        func makeNSView(context: Context) -> DropDragView {
            let view = DropDragView()
            view.onTargeted = { isTargeted = $0 }
            updateNSView(view, context: context)
            return view
        }

        func updateNSView(_ nsView: DropDragView, context: Context) {
            nsView.onDrop = onDrop
            nsView.onDoubleClick = onDoubleClick
            nsView.onPan = onPan
            nsView.isZoomed = isZoomed
        }
    }
}


/// The draggable before/after line, drawn over the photo's fitted frame.
struct SplitHandle: View {
    @Binding var position: CGFloat
    /// The photo's aspect ratio when fitted; nil when it fills the window (100 % view).
    let aspect: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let frame = fitted(in: geo.size)
            let x = frame.minX + frame.width * position
            ZStack {
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: frame.height)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                Circle()
                    .fill(.white)
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.black))
            }
            .frame(width: 44, height: frame.height)
            .contentShape(Rectangle())
            .position(x: x, y: frame.midY)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("split")).onChanged { value in
                position = min(1, max(0, (value.location.x - frame.minX) / frame.width))
            })
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }

            Text("Before").splitLabel().position(x: frame.minX + 40, y: frame.minY + 22)
            Text("After").splitLabel().position(x: frame.maxX - 36, y: frame.minY + 22)
        }
        .coordinateSpace(name: "split")
    }

    private func fitted(in size: CGSize) -> CGRect {
        guard let aspect else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / aspect, size.height)
        let (w, h) = (scale * aspect, scale)
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}


private extension Text {
    func splitLabel() -> some View {
        font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule())
            .allowsHitTesting(false)
    }
}


/// The 100 % view: draws only the visible part of the full-resolution image, one image pixel per screen pixel,
/// with the original (scaled to the same geometry) for before/after.
struct ActualPixels: NSViewRepresentable {
    let after: CGImage
    let before: CGImage?
    let center: CGPoint
    let showBefore: Bool
    let split: CGFloat?
    let hasAlpha: Bool
    let backdrop: NSColor?

    func makeNSView(context: Context) -> Canvas { Canvas() }

    func updateNSView(_ view: Canvas, context: Context) {
        view.model = self
        view.needsDisplay = true
    }

    final class Canvas: NSView {
        var model: ActualPixels?

        private static let checker: NSColor = {
            let tile = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
                NSColor(white: 0.85, alpha: 1).setFill(); rect.fill()
                NSColor(white: 0.65, alpha: 1).setFill()
                NSRect(x: 0, y: 0, width: 12, height: 12).fill(); NSRect(x: 12, y: 12, width: 12, height: 12).fill()
                return true
            }
            return NSColor(patternImage: tile)
        }()

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.setFill()
            bounds.fill()
            guard let m = model, let ctx = NSGraphicsContext.current?.cgContext else { return }
            let scale = window?.backingScaleFactor ?? 2
            let (w, h) = (CGFloat(m.after.width), CGFloat(m.after.height))
            // Image rectangle in view points (y up), positioned so `center` sits in the middle of the view.
            let imageRect = CGRect(x: bounds.midX - m.center.x / scale, y: bounds.midY - (h - m.center.y) / scale,
                                   width: w / scale, height: h / scale)
            let visible = imageRect.intersection(bounds)
            guard !visible.isEmpty else { return }
            // The same area in image pixels (top-left origin).
            let px = CGRect(x: (visible.minX - imageRect.minX) * scale, y: (imageRect.maxY - visible.maxY) * scale,
                            width: visible.width * scale, height: visible.height * scale).integral

            func draw(_ image: CGImage, quality: CGInterpolationQuality, clip: CGRect? = nil) {
                let ratio = CGFloat(image.width) / w
                let src = CGRect(x: px.minX * ratio, y: px.minY * ratio, width: px.width * ratio, height: px.height * ratio).integral
                guard let piece = image.cropping(to: src) else { return }
                ctx.saveGState()
                if let clip { ctx.clip(to: clip) }
                ctx.interpolationQuality = quality
                ctx.draw(piece, in: visible)
                ctx.restoreGState()
            }

            if m.showBefore, let before = m.before {
                draw(before, quality: .high)
                return
            }
            if m.hasAlpha {
                (m.backdrop ?? Self.checker).setFill()
                visible.fill()
            }
            draw(m.after, quality: .none)
            if let split = m.split, let before = m.before {
                draw(before, quality: .high, clip: CGRect(x: 0, y: 0, width: bounds.width * split, height: bounds.height))
            }
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
