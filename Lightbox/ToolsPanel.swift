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
                Text("Background").font(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Model", selection: $editor.upscaleModel) {
                        ForEach(AIModel.upscalers) { Text($0.title).tag($0) }
                    }
                    Text(editor.upscaleModel.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("Scale", selection: $editor.upscaleFactor) {
                        ForEach([2, 3, 4], id: \.self) { Text("\($0)×").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if let size = editor.layer?.pixelSize {
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
                Text("Upscale").font(.headline)
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
                Toggle(isOn: $editor.splitCompare) {
                    Label("Split", systemImage: "rectangle.split.2x1")
                }
                .help("Before/after line you can drag across the photo (⌘\\)")
            }
            .toggleStyle(.button)
            .disabled(!editor.isModified)

            Divider()

            HStack {
                Picker("Format", selection: $editor.exportFormat) {
                    ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 140)
                Spacer()
                Button("Save As…") { editor.saveWithPanel() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s")
            }
            if editor.layer?.mask != nil && !editor.exportFormat.supportsAlpha {
                Text("JPEG has no transparency; the cutout is saved on white.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(editor.layer == nil || editor.isBusy)
        .padding(16)
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
