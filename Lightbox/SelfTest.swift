//
//  SelfTest.swift
//  Lightbox
//
//  Debug builds only: `Lightbox --selftest <photo>` runs cutout + upscale headless and writes the results
//  next to the photo (inside the app container, because of the sandbox), then quits.
//

#if DEBUG
import Foundation
import AppKit

enum SelfTest {
    /// `--snapshot <dir>`: 10 s after launch, writes each window's contents as PNG into <dir> (container path).
    /// Set by the app once its editor exists, for `--demo-cutout`.
    static weak var editor: Editor?

    static func scheduleSnapshot() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        Task { @MainActor in
            // `--demo-cutout`: once a photo is open, remove its background and show the before/after split.
            if args.contains("--demo-cutout") {
                while editor?.layer == nil || editor?.isBusy == true { try? await Task.sleep(for: .milliseconds(200)) }
                // `--demo-upscale`: upscale 2x (fast model) first, so the cutout runs on the upscaled image.
                if args.contains("--demo-upscale") {
                    editor?.upscaleModel = .realESRGAN
                    editor?.upscaleTexture = AIModel.realESRGAN.defaultTexture
                    editor?.upscaleFactor = 2
                    editor?.upscale()
                    try? await Task.sleep(for: .milliseconds(300))
                    while editor?.isBusy == true { try? await Task.sleep(for: .milliseconds(200)) }
                }
                editor?.removeBackground()
                try? await Task.sleep(for: .milliseconds(300))
                while editor?.isBusy == true { try? await Task.sleep(for: .milliseconds(200)) }
                editor?.splitPosition = 0.45
                editor?.splitCompare = true
                // `--demo-zoom x,y`: then switch to the 100 % view centred on that point (fractions of the photo).
                if let z = args.firstIndex(of: "--demo-zoom"), z + 1 < args.count, let size = editor?.layer?.pixelSize {
                    let f = args[z + 1].split(separator: ",").compactMap { Double($0) }
                    editor?.toggleZoom(at: CGPoint(x: size.width * f[0], y: size.height * f[1]))
                }
                try? await Task.sleep(for: .seconds(1))
            } else {
                try? await Task.sleep(for: .seconds(10))
            }
            for (n, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("window\(n)-\(window.title).png"))
                print("snapshot window\(n) \(window.title) \(window.frame)")
            }
        }
    }

    static func runIfRequested() {
        scheduleSnapshot()
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        Task.detached {
            do {
                func time<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
                    let start = Date()
                    let result = try await work()
                    print(String(format: "%@ %.2fs", label, Date().timeIntervalSince(start)))
                    return result
                }
                let (image, metadata) = try PhotoIO.load(url)
                print("loaded \(image.width)x\(image.height) \(image.bitsPerComponent)bpc \(image.colorSpace?.name as String? ?? "?")")
                let engine = Engine.shared
                await time("warm-up") { await engine.warmUp() }
                for model in AIModel.cutout {
                    let mask = try await time("matte \(model.rawValue)") { try await engine.matte(for: image, using: model) }
                    let cut = try await time("  composite (decontaminate)") { try engine.composite(image, mask: mask) }
                    try PhotoIO.write(cut, to: url.deletingPathExtension().appendingPathExtension("\(model.rawValue).png"), format: .png, metadata: metadata)
                    let psd = try await time("  layered PSD") { try engine.layeredPSD(image, mask: mask) }
                    try psd.write(to: url.deletingPathExtension().appendingPathExtension("\(model.rawValue).psd"))
                }
                if args.contains("--cutout-only") { print("selftest ok"); exit(0) }
                for model in AIModel.upscalers {
                    for factor in [2, 4] {
                        let up = try await time("upscale \(model.rawValue) \(factor)x") {
                            try await engine.upscale(image, using: model, factor: factor) { _ in }
                        }
                        try PhotoIO.write(up, to: url.deletingPathExtension().appendingPathExtension("\(model.rawValue)-\(factor)x.png"), format: .png, metadata: metadata)
                        if model.defaultTexture > 0 {
                            let textured = try await time("  texture \(Int(model.defaultTexture * 100))%") {
                                try engine.retainTexture(ai: up, original: image, amount: model.defaultTexture)
                            }
                            try PhotoIO.write(textured, to: url.deletingPathExtension().appendingPathExtension("\(model.rawValue)-\(factor)x-texture.png"), format: .png, metadata: metadata)
                        }
                    }
                }
                print("selftest ok")
                exit(0)
            } catch {
                print("selftest FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
}
#endif
