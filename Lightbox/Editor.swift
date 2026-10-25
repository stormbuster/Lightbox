//
//  Editor.swift
//  Lightbox
//

import AppKit
import Observation
import UniformTypeIdentifiers


@Observable
final class Editor {
    private(set) var layer: Layer?
    private(set) var original: Layer?
    private(set) var sourceURL: URL?
    private(set) var documentID = UUID()
    private var metadata: PhotoMetadata?
    private var history: [Layer] = []

    private(set) var isBusy = false
    private(set) var status = ""
    private(set) var progress: Double?
    var errorMessage: String?
    var showOriginal = false
    var splitCompare = false
    var splitPosition: CGFloat = 0.5
    private(set) var shooting: ShootingInfo?
    private(set) var tuning = CutoutTuning.standard

    var cutoutModel: AIModel = .birefnetMatting
    var upscaleModel: AIModel = .bhiDAT2
    var upscaleFactor = 2
    var exportFormat: ExportFormat = .png

    private var job: Task<Void, Never>?

    var displayedPreview: CGImage? { showOriginal ? original?.preview : layer?.preview }
    var canUndo: Bool { !history.isEmpty }
    var isModified: Bool { canUndo }

    // MARK: Opening

    func load(_ url: URL) {
        perform("Opening \(url.lastPathComponent)…", record: false) {
            let (image, metadata) = try PhotoIO.load(url)
            let (rgb, mask) = try Engine.shared.split(image)
            let layer = try Engine.shared.makeLayer(rgb: rgb, mask: mask)
            return { editor in
                editor.sourceURL = url
                editor.metadata = metadata
                editor.shooting = ShootingInfo(metadata)
                editor.tuning = editor.shooting?.tuning ?? .standard
                editor.cutoutModel = editor.tuning.model
                editor.showOriginal = false
                editor.splitCompare = false
                editor.original = layer
                editor.history = []
                editor.exportFormat = mask == nil ? editor.formatMatching(url) : .png
                editor.upscaleModel = editor.isCleanOriginal(url) ? .nomosDAT2 : .bhiDAT2
                editor.documentID = UUID()
                return layer
            }
        }
    }

    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    // MARK: Editing

    func removeBackground() {
        guard let current = layer else { return }
        let (model, tuning) = (cutoutModel, tuning)
        perform("Removing background…") { [weak self] in
            let mask = try await Engine.shared.matte(for: current.rgb, using: model, tuning: tuning) { fraction in
                Task { @MainActor in self?.progress = fraction }
            }
            let layer = try Engine.shared.makeLayer(rgb: current.rgb, mask: mask)
            return { editor in
                if editor.exportFormat == .jpeg { editor.exportFormat = .png }
                return layer
            }
        }
    }

    func upscale() {
        guard let current = layer else { return }
        let (model, factor) = (upscaleModel, upscaleFactor)
        perform("Upscaling \(factor)×…") { [weak self] in
            let rgb = try await Engine.shared.upscale(current.rgb, using: model, factor: factor) { fraction in
                Task { @MainActor in self?.progress = fraction }
            }
            let mask = try current.mask.map {
                try Engine.shared.resize(mask: $0, to: CGSize(width: rgb.width, height: rgb.height))
            }
            let layer = try Engine.shared.makeLayer(rgb: rgb, mask: mask)
            return { _ in layer }
        }
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        layer = previous
    }

    func revert() {
        guard let original, layer != nil else { return }
        showOriginal = false
        splitCompare = false
        if let current = layer { history.append(current) }
        layer = original
    }

    func cancel() {
        job?.cancel()
    }

    // MARK: Saving

    func saveWithPanel() {
        guard let layer, !isBusy else { return }
        let format = exportFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.canCreateDirectories = true
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "Photo"
        let suffix = [layer.mask != nil ? "cutout" : nil,
                      layer.pixelSize != original?.pixelSize ? "\(layer.rgb.width)px" : nil].compactMap { $0 }
        panel.nameFieldStringValue = ([base] + suffix).joined(separator: " ") + "." + (format.type.preferredFilenameExtension ?? "png")
        if let folder = sourceURL?.deletingLastPathComponent() { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let metadata = metadata
        perform("Saving…", record: false) {
            let flatten = format.supportsAlpha ? nil : CGColor(gray: 1, alpha: 1)
            let image = try Engine.shared.composite(layer.rgb, mask: layer.mask, flattenOnto: flatten)
            try PhotoIO.write(image, to: url, format: format, metadata: metadata)
            return { _ in layer }
        }
    }

    // MARK: Helpers

    /// Runs `work` off the main actor; the returned closure applies the result on the main actor and yields the new layer.
    private func perform(_ message: String, record: Bool = true,
                         _ work: @escaping @Sendable () async throws -> @MainActor (Editor) -> Layer) {
        guard !isBusy else { return }
        isBusy = true
        status = message
        progress = nil
        job = Task {
            do {
                let apply = try await Task.detached(priority: .userInitiated) { try await work() }.value
                try Task.checkCancellation()
                let previous = layer
                let next = apply(self)
                if record, let previous { history.append(previous) }
                layer = next
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
            progress = nil
            status = ""
        }
    }

    /// RAW, TIFF and PNG files carry no lossy compression: use the faithful model; JPEG/HEIC/WebP get the restoring one.
    private func isCleanOriginal(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .rawImage) || type.conforms(to: .tiff) || type.conforms(to: .png)
    }

    private func formatMatching(_ url: URL) -> ExportFormat {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .tiff }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heic }
        if type.conforms(to: .png) { return .png }
        return .tiff
    }
}
