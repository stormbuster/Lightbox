//
//  ToolsPanel.swift
//  Lightbox
//

import SwiftUI
import AppKit


struct ToolsPanel: View {
    @Environment(Editor.self) private var editor
    @State private var sampler = NSColorSampler()

    var body: some View {
        @Bindable var editor = editor

        VStack(alignment: .leading, spacing: 14) {
            header

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Model", selection: $editor.upscaleModel) {
                        ForEach(AIModel.upscalers) { Text($0.title).tag($0) }
                    }
                    .onChange(of: editor.upscaleModel) { editor.upscaleTexture = editor.upscaleModel.defaultTexture }
                    Text(editor.upscaleModel.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("Scale", selection: $editor.upscaleFactor) {
                        ForEach([2, 3, 4], id: \.self) { Text("\($0)×").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("Texture")
                        Slider(value: $editor.upscaleTexture, in: 0...1) { editing in
                            if !editing { editor.applyTexture() }
                        }
                        Text("\(Int((editor.upscaleTexture * 100).rounded()))%")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                    }
                    .help("Adds the original's own grain and skin texture back, so upscaled people don't look plastic.")
                    if let size = editor.original?.pixelSize {
                        Text("→ \(Int(size.width) * editor.upscaleFactor) × \(Int(size.height) * editor.upscaleFactor) px")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Button {
                        editor.upscale()
                    } label: {
                        Label("Upscale", systemImage: "arrow.up.left.and.arrow.down.right")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
                .padding(4)
            } label: {
                StepHeader(title: "Upscale", systemImage: "arrow.up.left.and.arrow.down.right",
                           summary: editor.state.upscale.map { "\($0.factor)× · \($0.model.title.components(separatedBy: " (").first ?? "")" },
                           isVisible: editor.state.upscaleVisible) { editor.setUpscaleVisible($0) }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Model", selection: $editor.cutoutModel) {
                        ForEach(AIModel.cutout) { Text($0.title).tag($0) }
                    }
                    Text(editor.cutoutModel.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let shooting = editor.shooting {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(shooting.summary, systemImage: "camera")
                                .font(.caption.weight(.medium))
                            if !editor.tuning.reasons.isEmpty {
                                Text("Tuned for " + editor.tuning.reasons.joined(separator: "; ") + ".")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }
                    if editor.state.upscale != nil && editor.state.upscaleVisible {
                        Text("Runs on the upscaled image, so edges are cut at the higher resolution.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        editor.removeBackground()
                    } label: {
                        Label("Remove Background", systemImage: "person.and.background.dotted")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    Text("Preview backdrop").font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 4)
                    HStack(spacing: 8) {
                        Picker("Preview backdrop", selection: $editor.backdrop) {
                            ForEach(Backdrop.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        ColorPicker("Backdrop colour", selection: $editor.backdropColor, supportsOpacity: false)
                            .labelsHidden()
                            .onChange(of: editor.backdropColor) { editor.backdrop = .color }
                        Button {
                            let target = editor
                            sampler.show { picked in
                                guard let picked else { return }
                                let color = Color(nsColor: picked)
                                Task { @MainActor in
                                    target.backdropColor = color
                                    target.backdrop = .color
                                }
                            }
                        } label: {
                            Image(systemName: "eyedropper")
                        }
                        .help("Pick a backdrop colour from anywhere on screen")
                    }
                    .disabled(editor.layer?.mask == nil)
                }
                .padding(4)
            } label: {
                StepHeader(title: "Background", systemImage: "person.and.background.dotted",
                           summary: editor.state.cutout.map { $0.model == .birefnetMatting ? "Soft edges" : "Crisp edges" },
                           isVisible: editor.state.cutoutVisible) { editor.setCutoutVisible($0) }
            }

            if editor.isBusy {
                VStack(alignment: .leading, spacing: 6) {
                    if let progress = editor.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack {
                        Text(editor.status).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { editor.cancel() }.controlSize(.small)
                    }
                }
            }

            HStack {
                Button("Undo", systemImage: "arrow.uturn.backward") { editor.undo() }
                    .disabled(!editor.canUndo)
                Button("Revert") { editor.revert() }
                    .disabled(!editor.isModified)
                Spacer()
            }

            HStack {
                Text("Compare").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: $editor.showOriginal) {
                    Label("Original", systemImage: "eye")
                }
                .help("Show the original photo (\\)")
                .disabled(!editor.isModified)
                .disabled(!editor.isModified)
                Toggle(isOn: $editor.splitCompare) {
                    Label("Split", systemImage: "rectangle.split.2x1")
                }
                .help("Before/after line you can drag across the photo (⌘\\)")
                .disabled(!editor.isModified)
                Toggle(isOn: Binding(get: { editor.isZoomed }, set: { _ in editor.toggleZoom(at: nil) })) {
                    Text("100%").monospacedDigit()
                }
                .help("Actual pixels (⌘1). Double-click the photo to zoom there; drag or scroll to move around.")
            }
            .toggleStyle(.button)

            Divider()

            HStack {
                Picker("Format", selection: $editor.exportFormat) {
                    ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 170)
                Spacer()
                Button("Save As…") { editor.saveWithPanel() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s")
            }
            if editor.layer?.mask != nil && !editor.exportFormat.supportsAlpha {
                Text("JPEG has no transparency; the cutout is saved on white.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if editor.exportFormat == .psd {
                Text(editor.layer?.mask != nil
                     ? "Layers: the subject with an editable layer mask over the hidden original. Paint the mask in Photoshop, Affinity or Pixelmator to refine the cutout."
                     : "One layer with the photo.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(editor.layer == nil || editor.isBusy)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .padding(.top, 46)   // 24 pt below the close/minimise buttons that fade in on hover
        .ignoresSafeArea(.container, edges: .top)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(editor.sourceURL?.lastPathComponent ?? "No photo")
                .font(.headline).lineLimit(1).truncationMode(.middle)
            if let layer = editor.layer {
                Text("\(layer.rgb.width) × \(layer.rgb.height) px" + (layer.mask != nil ? " · transparent background" : ""))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}


/// A step's title row, styled like a layer: an eye toggle (once the step has a result), the name and what it applied.
struct StepHeader: View {
    let title: String
    let systemImage: String
    let summary: String?
    let isVisible: Bool
    let setVisible: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                setVisible(!isVisible)
            } label: {
                Image(systemName: summary == nil ? "eye.slash" : isVisible ? "eye" : "eye.slash")
                    .frame(width: 18)
                    .foregroundStyle(summary != nil && isVisible ? .primary : .tertiary)
            }
            .buttonStyle(.plain)
            .disabled(summary == nil)
            .help(summary == nil ? "Not applied yet" : isVisible ? "Hide this step" : "Show this step")
            Text(title).font(.headline)
            if let summary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
