//
//  Editor.swift
//  Lightbox
//
//  Edits are two non-destructive steps applied in order, like layers: Upscale (to the original's colour), then
//  Background (a matte computed on whatever is visible beneath it). Each step keeps its result and can be hidden
//  with its eye toggle without recomputing; the displayed layer is composed from the visible steps.
//

import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers


enum Backdrop: String, CaseIterable, Identifiable {
    case checkerboard = "Transparent", color = "Colour"
    var id: String { rawValue }
}


/// A computed upscale of the original photo.
nonisolated struct UpscaleStep: Sendable {
    /// The model's output, before texture retention.
    var rgb: CGImage
    var factor: Int
    var model: AIModel
    /// How much of the original's fine texture (grain, pores) to add back, 0…1.
    var texture: Double
}


/// A computed alpha matte; resized to whatever it is shown over.
nonisolated struct CutoutStep: Sendable {
    var mask: CGImage
    var model: AIModel
}


/// Everything undo needs to restore.
nonisolated struct EditState: Sendable {
    var upscale: UpscaleStep?
    var cutout: CutoutStep?
    var upscaleVisible = true
    var cutoutVisible = true
}


@Observable
final class Editor {
    private(set) var layer: Layer?
    private(set) var original: Layer?
    private(set) var sourceURL: URL?
    private(set) var documentID = UUID()
    private var metadata: PhotoMetadata?

    private(set) var state = EditState()
    private var history: [EditState] = []

    private(set) var isBusy = false
    private(set) var status = ""
    private(set) var progress: Double?
    var errorMessage: String?
    var showOriginal = false
    var splitCompare = false
    var splitPosition: CGFloat = 0.5
    /// What shows behind a cutout in the preview (never saved).
    var backdrop: Backdrop = .checkerboard
    var backdropColor = Color.white
    private(set) var shooting: ShootingInfo?
    private(set) var tuning = CutoutTuning.standard

    /// 100 % view: one image pixel per screen pixel, centred on `zoomCenter` (image pixels of the displayed layer).
    private(set) var isZoomed = false
    private(set) var zoomCenter = CGPoint.zero

    var cutoutModel: AIModel = .birefnetMatting
    var upscaleModel: AIModel = .bhiDAT2
    var upscaleFactor = 2
    var upscaleTexture = AIModel.bhiDAT2.defaultTexture
    var exportFormat: ExportFormat = .png

    private var job: Task<Void, Never>?

    var displayedPreview: CGImage? { showOriginal ? original?.preview : layer?.preview }
    var canUndo: Bool { !history.isEmpty }
    var isModified: Bool { state.upscale != nil || state.cutout != nil }

    // MARK: Opening

    func load(_ url: URL) {
        perform("Opening \(url.lastPathComponent)…") {
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
                editor.isZoomed = false
                editor.original = layer
                editor.layer = layer
                editor.state = EditState()
                editor.history = []
                editor.exportFormat = mask == nil ? editor.formatMatching(url) : .png
                editor.upscaleModel = editor.isCleanOriginal(url) ? .nomosDAT2 : .bhiDAT2
                editor.upscaleTexture = editor.upscaleModel.defaultTexture
                editor.documentID = UUID()
            }
        }
    }

    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    // MARK: Steps

    /// Upscales the original photo's colour; a cutout above it is resized to match (or can be re-run on the result).
    func upscale() {
        guard let original else { return }
        let (model, factor, texture, state) = (upscaleModel, upscaleFactor, upscaleTexture, state)
        perform("Upscaling \(factor)×…") { [weak self] in
            let rgb = try await Engine.shared.upscale(original.rgb, using: model, factor: factor) { fraction in
                Task { @MainActor in self?.progress = fraction }
            }
            var next = state
            next.upscale = UpscaleStep(rgb: rgb, factor: factor, model: model, texture: texture)
            next.upscaleVisible = true
            let layer = try Self.compose(original: original, state: next)
            return { editor in editor.commit(next, layer: layer) }
        }
    }

    /// Computes the matte on what is currently visible beneath the Background step (the upscale, if shown).
    func removeBackground() {
        guard let original else { return }
        let (model, tuning, state) = (cutoutModel, tuning, state)
        let base = state.upscaleVisible ? state.upscale?.rgb ?? original.rgb : original.rgb
        perform("Removing background…") { [weak self] in
            let mask = try await Engine.shared.matte(for: base, using: model, tuning: tuning) { fraction in
                Task { @MainActor in self?.progress = fraction }
            }
            var next = state
            next.cutout = CutoutStep(mask: mask, model: model)
            next.cutoutVisible = true
            let layer = try Self.compose(original: original, state: next)
            return { editor in
                if editor.exportFormat == .jpeg { editor.exportFormat = .png }
                editor.commit(next, layer: layer)
            }
        }
    }

    func setUpscaleVisible(_ visible: Bool) {
        guard state.upscale != nil, state.upscaleVisible != visible else { return }
        var next = state
        next.upscaleVisible = visible
        recompose(next)
    }

    /// Re-applies texture retention to the existing upscale (no new AI pass).
    func applyTexture() {
        guard let up = state.upscale, up.texture != upscaleTexture else { return }
        var next = state
        next.upscale?.texture = upscaleTexture
        recompose(next)
    }

    func setCutoutVisible(_ visible: Bool) {
        guard state.cutout != nil, state.cutoutVisible != visible else { return }
        var next = state
        next.cutoutVisible = visible
        recompose(next)
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        recompose(previous, record: false)
    }

    func revert() {
        guard isModified else { return }
        showOriginal = false
        splitCompare = false
        recompose(EditState())
    }

    func cancel() {
        job?.cancel()
    }

    /// The visible steps applied to the original. A matte computed at another size is resized to fit.
    nonisolated private static func compose(original: Layer, state: EditState) throws -> Layer {
        var rgb = original.rgb
        if state.upscaleVisible, let up = state.upscale {
            rgb = try Engine.shared.retainTexture(ai: up.rgb, original: original.rgb, amount: up.texture)
        }
        var mask = state.cutoutVisible ? state.cutout?.mask : original.mask
        if let m = mask, m.width != rgb.width || m.height != rgb.height {
            mask = try Engine.shared.resize(mask: m, to: CGSize(width: rgb.width, height: rgb.height))
        }
        if state.upscale == nil && state.cutout == nil { return original }
        return try Engine.shared.makeLayer(rgb: rgb, mask: mask)
    }

    private func recompose(_ next: EditState, record: Bool = true) {
        guard let original else { return }
        perform("Updating…") {
            let layer = try Self.compose(original: original, state: next)
            return { editor in editor.commit(next, layer: layer, record: record) }
        }
    }

    private func commit(_ next: EditState, layer: Layer, record: Bool = true) {
        if record { history.append(state) }
        let oldSize = self.layer?.pixelSize
        state = next
        self.layer = layer
        if let oldSize, oldSize != layer.pixelSize {   // keep the 100 % view on the same spot
            zoomCenter = CGPoint(x: zoomCenter.x * layer.pixelSize.width / oldSize.width,
                                 y: zoomCenter.y * layer.pixelSize.height / oldSize.height)
        }
    }

    // MARK: 100 % view

    /// Toggles between fit-to-window and actual pixels, zooming in on `point` (image pixels of the displayed layer).
    func toggleZoom(at point: CGPoint?) {
        guard let size = layer?.pixelSize else { return }
        if isZoomed {
            isZoomed = false
        } else {
            zoomCenter = point ?? CGPoint(x: size.width / 2, y: size.height / 2)
            isZoomed = true
        }
    }

    func pan(by delta: CGPoint) {
        guard isZoomed, let size = layer?.pixelSize else { return }
        zoomCenter = CGPoint(x: min(max(zoomCenter.x - delta.x, 0), size.width),
                             y: min(max(zoomCenter.y - delta.y, 0), size.height))
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
        perform("Saving…") {
            if format == .psd {
                try Engine.shared.layeredPSD(layer.rgb, mask: layer.mask).write(to: url, options: .atomic)
            } else {
                let flatten = format.supportsAlpha ? nil : CGColor(gray: 1, alpha: 1)
                let image = try Engine.shared.composite(layer.rgb, mask: layer.mask, flattenOnto: flatten)
                try PhotoIO.write(image, to: url, format: format, metadata: metadata)
            }
            return { _ in }
        }
    }

    // MARK: Helpers

    /// Runs `work` off the main actor; the returned closure applies the result on the main actor.
    private func perform(_ message: String, _ work: @escaping @Sendable () async throws -> @MainActor (Editor) -> Void) {
        guard !isBusy else { return }
        isBusy = true
        status = message
        progress = nil
        job = Task {
            do {
                let apply = try await Task.detached(priority: .userInitiated) { try await work() }.value
                try Task.checkCancellation()
                apply(self)
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
