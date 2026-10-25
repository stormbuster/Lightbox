//
//  Engine.swift
//  Lightbox
//
//  Core ML inference: BiRefNet background mattes and tiled 4x super-resolution.
//  Models are converted from the official PyTorch weights by tools/ (see README).
//

import CoreML
import CoreImage
import CoreVideo
import Accelerate


nonisolated enum AIModel: String, CaseIterable, Identifiable, Sendable {
    case birefnetHR = "BiRefNet_HR_2048"
    case birefnetMatting = "BiRefNet_HR_Matting_2048"
    case nomosDAT2 = "Nomos2_DAT2_x4"
    case bhiDAT2 = "BHI_DAT2_Real_x4"
    case realESRGAN = "RealESRGAN_x4"
    case vitMatte = "ViTMatte_Base_1024"

    static let cutout: [AIModel] = [.birefnetMatting, .birefnetHR]
    static let upscalers: [AIModel] = [.nomosDAT2, .bhiDAT2, .realESRGAN]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .birefnetHR: "Crisp edges (BiRefNet HR)"
        case .birefnetMatting: "Soft edges (BiRefNet Matting)"
        case .nomosDAT2: "Faithful (Nomos2 DAT2)"
        case .bhiDAT2: "Restore (BHI DAT2)"
        case .realESRGAN: "Fast (Real-ESRGAN)"
        case .vitMatte: "ViTMatte"
        }
    }

    var detail: String {
        switch self {
        case .birefnetHR: "Hard, clean outlines for products and objects with sharp edges."
        case .birefnetMatting: "Partial transparency for hair, fur, motion and focus blur. Best for people and animals."
        case .nomosDAT2: "For clean camera originals (RAW, TIFF, high-quality JPEG). Adds detail without inventing texture."
        case .bhiDAT2: "For compressed, noisy or slightly soft photos: removes JPEG blocks and noise while upscaling."
        case .realESRGAN: "About 4× faster on the Neural Engine. Smoother, slightly painterly look."
        case .vitMatte: "Trimap matting for hair and fine edges."
        }
    }

    /// Measured on M5 Pro: DAT2's window attention takes 70 s/tile on the Neural Engine vs 0.48 s on the GPU;
    /// Real-ESRGAN is fastest on the Neural Engine (0.13 s vs 0.22 s per 256 px tile).
    var computeUnits: MLComputeUnits {
        self == .realESRGAN ? .cpuAndNeuralEngine : .cpuAndGPU
    }
}


nonisolated enum EngineError: LocalizedError {
    case missingModel(String)
    case noOutput
    case tooLarge(Int, Int)
    case render

    var errorDescription: String? {
        switch self {
        case .missingModel(let name): "The \(name) model is missing from the app bundle. Run tools/build-models.sh and rebuild."
        case .noOutput: "The model returned no image."
        case .tooLarge(let w, let h): "The result would be \(w) × \(h) px, which is too large. Pick a smaller scale."
        case .render: "Could not render the image."
        }
    }
}


/// A photo as opaque colour plus an optional alpha matte, so cutouts can still be upscaled at full quality
/// (the colour goes through the upscaler, the matte through a smooth resampler).
nonisolated struct Layer: Sendable {
    var rgb: CGImage
    var mask: CGImage?
    var preview: CGImage

    var pixelSize: CGSize { CGSize(width: rgb.width, height: rgb.height) }
}


actor Engine {
    static let shared = Engine()

    private var models: [AIModel: MLModel] = [:]
    // Image operations below are nonisolated (CIContext is thread-safe), so opening and saving photos
    // never waits behind a running model; only inference is serialised on the actor.
    private nonisolated let context = CIContext(options: [.cacheIntermediates: false])
    private nonisolated let linearGray = CGColorSpace(name: CGColorSpace.linearGray)!
    private nonisolated let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Load the default models and run one blank prediction each, so the first click doesn't pay the GPU compile.
    func warmUp() {
        for id in [AIModel.birefnetMatting, .bhiDAT2] {
            guard let model = try? model(id), let input = try? pixelBuffer(inputSize(of: model)) else { continue }
            _ = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)]))
        }
    }

    private func model(_ id: AIModel) throws -> MLModel {
        if let cached = models[id] { return cached }
        guard let url = Bundle.main.url(forResource: id.rawValue, withExtension: "mlmodelc") else {
            throw EngineError.missingModel(id.title)
        }
        let config = MLModelConfiguration()
        config.computeUnits = id.computeUnits
        let loaded = try MLModel(contentsOf: url, configuration: config)
        models[id] = loaded
        return loaded
    }

    private func inputSize(of model: MLModel) -> CGSize {
        let constraint = model.modelDescription.inputDescriptionsByName["image"]!.imageConstraint!
        return CGSize(width: constraint.pixelsWide, height: constraint.pixelsHigh)
    }

    private func pixelBuffer(_ size: CGSize) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
              let buffer else { throw EngineError.render }
        return buffer
    }

    nonisolated private func workingSpace(_ image: CGImage) -> CGColorSpace {
        guard let space = image.colorSpace, space.model == .rgb else { return sRGB }
        return space
    }

    nonisolated private func resample(_ image: CGImage, to size: CGSize) -> CIImage {
        let input = CIImage(cgImage: image)
        return input.applyingFilter("CIBicubicScaleTransform", parameters: [
            kCIInputScaleKey: size.height / input.extent.height,
            kCIInputAspectRatioKey: (size.width / input.extent.width) / (size.height / input.extent.height),
            "inputB": 1.0 / 3, "inputC": 1.0 / 3,
        ])
    }

    // MARK: Background removal

    /// Full-resolution alpha matte (8-bit linear gray) for the photo.
    ///
    /// BiRefNet sees the whole photo at 2048 px and decides what the subject is; its edges are soft but clean. With
    /// *Soft edges*, ViTMatte then works out hair at native resolution (`hairMatte`), and its result is used only where
    /// it finds strand-like detail. (Re-running BiRefNet on native-resolution tiles was tried and dropped: a tile that
    /// sees only part of a limb loses context and smears its edge.)
    func matte(for rgb: CGImage, using id: AIModel, tuning: CutoutTuning = .standard,
               progress: @Sendable (Double) -> Void = { _ in }) throws -> CGImage {
        let model = try model(id)
        let (w, h) = (rgb.width, rgb.height)
        var source = CIImage(cgImage: rgb)
        if tuning.denoise {   // model input only; the photo's own pixels are untouched
            source = source.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.03, "inputSharpness": 0.5])
        }
        let space = workingSpace(rgb)
        let extent = CGRect(x: 0, y: 0, width: w, height: h)

        let coarse = try resize(mask: predictMask(model, source: source, rect: extent, space: space), to: extent.size)
        #if DEBUG
        if ProcessInfo.processInfo.environment["LIGHTBOX_NOREFINE"] == "1" { return coarse }
        #endif
        progress(0.2)
        var alpha = plane(of: coarse, bounds: extent)
        var hair = id == .birefnetMatting && min(w, h) >= 1024
        #if DEBUG
        if ProcessInfo.processInfo.environment["LIGHTBOX_NOHAIR"] == "1" { hair = false }
        #endif
        if hair {
            alpha = try hairMatte(alpha, source: source, space: space, width: w, height: h, tuning: tuning, progress: progress)
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["LIGHTBOX_RAW"] == "1" { return try grayImage(alpha, width: w, height: h) }
        #endif
        return try grayImage(removeHaze(alpha, width: w, height: h), width: w, height: h)
    }

    /// Matting models leave a faint, smooth alpha tail beyond soft edges; after colour decontamination it shows as a
    /// skin-coloured glow. Fade alpha that is both faint and smooth, keep anything with strand-like local detail, and drop
    /// specks that are not near the solid subject.
    nonisolated private func removeHaze(_ alpha: [Float], width w: Int, height h: Int) -> [Float] {
        let local = ForegroundEstimator.blur(alpha, w, h, 7)
        let solid = alpha.map { $0 > 0.6 ? Float(1) : 0 }
        let near = ForegroundEstimator.blur(solid, w, h, ForegroundEstimator.odd(Double(max(w, h)) * 0.0075))
        var out = alpha
        for i in 0..<alpha.count {
            let a = alpha[i]
            guard a > 0, a < 1 else { continue }
            guard near[i] > 0.001 else { out[i] = 0; continue }
            let t = min(max((a - 0.04) / 0.18, 0), 1)
            let faint = t * t * (3 - 2 * t)                         // smoothstep(0.04, 0.22, a)
            let strand = min(abs(a - local[i]) * 12, 1)               // fine hair deviates from its neighbourhood
            out[i] = a * max(faint, strand)
        }
        return out
    }

    /// Stage 3, hair: ViTMatte computes exact partial transparency inside an "unknown" band of a trimap built from the
    /// segmentation (definite subject / definite background / unknown). The band reaches further outwards than inwards,
    /// because flyaway hair sits outside the segmentation edge. Runs on native-resolution 1024 px tiles.
    private func hairMatte(_ alpha: [Float], source: CIImage, space: CGColorSpace, width w: Int, height h: Int,
                           tuning: CutoutTuning, progress: @Sendable (Double) -> Void) throws -> [Float] {
        let model = try model(.vitMatte)
        let tile = Int(inputSize(of: model).width)
        let longest = Double(max(w, h))
        let outward = ForegroundEstimator.odd(longest * 0.012 * tuning.bandScale)
        let inward = ForegroundEstimator.odd(longest * 0.004 * tuning.bandScale)

        let solid = alpha.map { $0 > 0.5 ? Float(1) : 0 }
        let grown = ForegroundEstimator.blur(solid, w, h, outward)       // > 0  → within reach outside the subject
        let shrunk = ForegroundEstimator.blur(solid, w, h, inward)       // ≈ 1 → safely inside the subject
        var trimap = [Float](repeating: 0, count: alpha.count)
        for i in 0..<alpha.count {
            let unknown = (grown[i] > 0.002 && shrunk[i] < 0.998) || (alpha[i] > 0.03 && alpha[i] < 0.97)
            trimap[i] = unknown ? 0.5 : (alpha[i] > 0.5 ? 1 : 0)
        }

        var result = alpha, acc = [Float](repeating: 0, count: alpha.count), weight = [Float](repeating: 0, count: alpha.count)
        let overlap = tile / 8
        let xs = starts(length: w, tile: tile, overlap: overlap), ys = starts(length: h, tile: tile, overlap: overlap)
        let image = try pixelBuffer(CGSize(width: tile, height: tile))
        let tri = try grayBuffer(tile)
        var done = 0
        for ty in ys {
            for tx in xs {
                try Task.checkCancellation()
                done += 1
                let top = h - ty - tile
                var any = false
                for r in stride(from: 0, to: tile, by: 4) where !any {
                    let row = (top + r) * w + tx
                    for c in stride(from: 0, to: tile, by: 4) where trimap[row + c] == 0.5 { any = true; break }
                }
                guard any else { continue }

                let window = source.transformed(by: CGAffineTransform(translationX: CGFloat(-tx), y: CGFloat(-ty)))
                context.render(window, to: image, bounds: CGRect(x: 0, y: 0, width: tile, height: tile), colorSpace: space)
                fill(tri, from: trimap, imageWidth: w, x: tx, top: top, size: tile)
                let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "image": MLFeatureValue(pixelBuffer: image), "trimap": MLFeatureValue(pixelBuffer: tri)]))
                guard let matte = out.featureValue(for: "alpha")?.imageBufferValue else { throw EngineError.noOutput }
                let values = plane(of: CIImage(cvPixelBuffer: matte, options: [.colorSpace: linearGray]),
                                   bounds: CGRect(x: 0, y: 0, width: tile, height: tile))
                for r in 0..<tile {
                    let wy = feather(r, tile, overlap, atStart: ty + tile < h, atEnd: ty > 0)
                    for c in 0..<tile {
                        let i = (top + r) * w + tx + c
                        guard trimap[i] == 0.5 else { continue }
                        let wt = wy * feather(c, tile, overlap, atStart: tx > 0, atEnd: tx + tile < w)
                        acc[i] += values[r * tile + c] * wt
                        weight[i] += wt
                    }
                }
                progress(0.2 + 0.8 * Double(done) / Double(xs.count * ys.count))
            }
        }
        for i in 0..<result.count where weight[i] > 0 { result[i] = acc[i] / weight[i] }

        // Use ViTMatte only where its matte has strand-like texture (hair, fur). On smooth, out-of-focus edges such as
        // arms and legs it leaves faint streaks of background, so the segmentation's clean soft edge is kept there.
        // Measured on a 20 MP portrait: hair edges score 0.013-0.017, limbs 0.006-0.008.
        let local = ForegroundEstimator.blur(result, w, h, 7, passes: 1)
        let detail = vDSP.absolute(vDSP.subtract(result, local))
        let energy = ForegroundEstimator.blur(detail, w, h, 41, passes: 1)
        var blended = alpha
        for i in 0..<alpha.count where weight[i] > 0 {
            let t = min(max((energy[i] - 0.009) / 0.007, 0), 1)
            blended[i] = alpha[i] + t * t * (3 - 2 * t) * (result[i] - alpha[i])
        }
        return blended
    }

    private func grayBuffer(_ size: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_OneComponent8, attrs, &buffer) == kCVReturnSuccess,
              let buffer else { throw EngineError.render }
        return buffer
    }

    /// Copies a size × size window of a Float plane (0…1, row 0 = top) into an 8-bit gray pixel buffer.
    private func fill(_ buffer: CVPixelBuffer, from plane: [Float], imageWidth: Int, x: Int, top: Int, size: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for r in 0..<size {
            let src = (top + r) * imageWidth + x
            for c in 0..<size { base[r * stride + c] = UInt8((plane[src + c] * 255).rounded()) }
        }
    }

    /// One model pass over `rect` of the photo (resampled to the model's input), as an 8-bit matte at model size.
    private func predictMask(_ model: MLModel, source: CIImage, rect: CGRect, space: CGColorSpace) throws -> CGImage {
        let size = inputSize(of: model)
        let crop = source.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let scaled = crop.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: size.height / rect.height,
            kCIInputAspectRatioKey: (size.width / rect.width) / (size.height / rect.height),
        ])
        let input = try pixelBuffer(size)
        context.render(scaled, to: input, bounds: CGRect(origin: .zero, size: size), colorSpace: space)
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)]))
        guard let buffer = output.featureValue(for: "mask")?.imageBufferValue,
              let mask = context.createCGImage(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: linearGray]),
                                               from: CGRect(origin: .zero, size: size), format: .L8, colorSpace: linearGray)
        else { throw EngineError.noOutput }
        return mask
    }

    /// Tile origins covering `length` with at least `overlap` px shared between neighbours.
    nonisolated private func starts(length: Int, tile: Int, overlap: Int) -> [Int] {
        guard length > tile else { return [0] }
        let count = Int((Double(length - overlap) / Double(tile - overlap)).rounded(.up))
        return (0..<count).map { Int((Double(length - tile) * Double($0) / Double(count - 1)).rounded()) }
    }

    /// Linear ramp over `overlap` px at tile edges that border another tile.
    nonisolated private func feather(_ i: Int, _ n: Int, _ overlap: Int, atStart: Bool, atEnd: Bool) -> Float {
        var v: Float = 1
        if atStart { v = min(v, Float(i + 1) / Float(overlap)) }
        if atEnd { v = min(v, Float(n - i) / Float(overlap)) }
        return max(v, 1e-3)
    }

    /// Gray image as a Float plane (row 0 = top of `bounds`).
    nonisolated private func plane(of image: CGImage, bounds: CGRect) -> [Float] {
        plane(of: CIImage(cgImage: image), bounds: bounds)
    }

    nonisolated private func plane(of image: CIImage, bounds: CGRect) -> [Float] {
        var values = [Float](repeating: 0, count: Int(bounds.width) * Int(bounds.height))
        values.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(bounds.width) * 4, bounds: bounds, format: .Lf, colorSpace: linearGray)
        }
        return values
    }

    nonisolated private func grayImage(_ values: [Float], width: Int, height: Int) throws -> CGImage {
        var clipped = values
        vDSP.clip(clipped, to: 0...1, result: &clipped)
        let data = clipped.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: width * 4, size: CGSize(width: width, height: height), format: .Lf, colorSpace: linearGray)
        guard let out = context.createCGImage(image, from: image.extent, format: .L8, colorSpace: linearGray) else { throw EngineError.render }
        return out
    }

    nonisolated func resize(mask: CGImage, to size: CGSize) throws -> CGImage {
        let scaled = resample(mask, to: size)
        guard let out = context.createCGImage(scaled, from: CGRect(origin: .zero, size: size), format: .L8, colorSpace: linearGray)
        else { throw EngineError.render }
        return out
    }

    // MARK: Upscaling

    /// Tiled super-resolution: each tile carries `pad` px of context that is cropped away, so seams don't show.
    func upscale(_ rgb: CGImage, using id: AIModel, factor: Int,
                 progress: @Sendable (Double) -> Void) throws -> CGImage {
        let model = try model(id)
        let tile = Int(inputSize(of: model).width)
        let modelScale = 4
        let pad = 16
        let step = tile - 2 * pad
        let (w, h) = (rgb.width, rgb.height)
        let (outW, outH) = (w * factor, h * factor)
        guard outW * outH <= 1_200_000_000, max(outW, outH) <= 65_000 else { throw EngineError.tooLarge(outW, outH) }

        let space = workingSpace(rgb)
        guard let canvas = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw EngineError.render }
        canvas.interpolationQuality = .none
        let source = CIImage(cgImage: rgb).clampedToExtent()
        let input = try pixelBuffer(CGSize(width: tile, height: tile))
        let cols = (w + step - 1) / step, rows = (h + step - 1) / step

        for row in 0..<rows {
            for col in 0..<cols {
                try Task.checkCancellation()
                let (x, y) = (col * step, row * step)
                // render(to: CVPixelBuffer) ignores the bounds origin, so move the photo instead
                let window = source.transformed(by: CGAffineTransform(translationX: CGFloat(pad - x), y: CGFloat(pad - y)))
                context.render(window, to: input, bounds: CGRect(x: 0, y: 0, width: tile, height: tile), colorSpace: space)
                let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)]))
                guard let buffer = output.featureValue(for: "upscaled")?.imageBufferValue else { throw EngineError.noOutput }

                var result = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: space])
                if factor != modelScale {
                    result = result.applyingFilter("CILanczosScaleTransform", parameters: [
                        kCIInputScaleKey: Double(factor) / Double(modelScale), kCIInputAspectRatioKey: 1.0])
                }
                let (cw, ch) = (min(step, w - x), min(step, h - y))
                let core = CGRect(x: pad * factor, y: pad * factor, width: cw * factor, height: ch * factor)
                guard let piece = context.createCGImage(result, from: core, format: .RGBA8, colorSpace: space) else { throw EngineError.render }
                canvas.draw(piece, in: CGRect(x: x * factor, y: y * factor, width: cw * factor, height: ch * factor))
                progress(Double(row * cols + col + 1) / Double(rows * cols))
            }
        }
        guard let out = canvas.makeImage() else { throw EngineError.render }
        return out
    }

    // MARK: Compositing

    /// The visible image: colour with the matte applied as alpha (or the colour alone).
    nonisolated func composite(_ rgb: CGImage, mask: CGImage?, flattenOnto background: CGColor? = nil) throws -> CGImage {
        guard let mask else { return rgb }
        let space = workingSpace(rgb)
        var image = try decontaminated(rgb, mask: mask, space: space)
        if let background {
            image = image.composited(over: CIImage(color: CIColor(cgColor: background)).cropped(to: image.extent))
        }
        let format: CIFormat = rgb.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        guard let out = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: rgb.width, height: rgb.height),
                                              format: format, colorSpace: space) else { throw EngineError.render }
        return out
    }

    /// Premultiplied cutout whose edge colours have the background's colour removed (see ForegroundEstimator).
    nonisolated private func decontaminated(_ rgb: CGImage, mask: CGImage, space: CGColorSpace) throws -> CIImage {
        let (w, h) = (rgb.width, rgb.height)
        let (foreground, alpha) = try foregroundPlanes(rgb, mask: mask, space: space)
        // Interleave as premultiplied RGBA (Core Image's convention for float bitmaps).
        var planar = (0..<3).flatMap { vDSP.multiply(foreground[$0], alpha) } + alpha
        var rgba = [Float](repeating: 0, count: w * h * 4)
        try convert(&rgba, &planar, width: w, height: h, toPlanar: false)
        let data = rgba.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: space)
    }

    /// The subject's own colours (background bleed removed) as three 0…1 planes, plus the matte as a plane.
    nonisolated private func foregroundPlanes(_ rgb: CGImage, mask: CGImage, space: CGColorSpace) throws -> (rgb: [[Float]], alpha: [Float]) {
        let (w, h) = (rgb.width, rgb.height)
        let n = w * h
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        var rgba = [Float](repeating: 0, count: n * 4)
        var alpha = [Float](repeating: 0, count: n)
        rgba.withUnsafeMutableBytes { context.render(CIImage(cgImage: rgb), toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: space) }
        alpha.withUnsafeMutableBytes { context.render(CIImage(cgImage: mask), toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: extent, format: .Lf, colorSpace: linearGray) }
        var planar = [Float](repeating: 0, count: n * 4)
        try convert(&rgba, &planar, width: w, height: h, toPlanar: true)
        let rgb3 = (0..<3).map { Array(planar[$0 * n..<($0 + 1) * n]) }
        return (ForegroundEstimator.estimate(rgb: rgb3, alpha: alpha, width: w, height: h), alpha)
    }

    /// Layered Photoshop document: the subject (background bleed removed) with the cutout as an editable layer mask,
    /// over the hidden original photo. Without a matte, the photo alone.
    nonisolated func layeredPSD(_ rgb: CGImage, mask: CGImage?) throws -> Data {
        let space = workingSpace(rgb)
        let (w, h) = (rgb.width, rgb.height)
        let n = w * h
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        var rgba8 = [UInt8](repeating: 0, count: n * 4)
        rgba8.withUnsafeMutableBytes { context.render(CIImage(cgImage: rgb), toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: extent, format: .RGBA8, colorSpace: space) }
        let original = (0..<3).map { c in (0..<n).map { rgba8[$0 * 4 + c] } }
        let icc = space.copyICCData() as Data?
        guard let mask else {
            return PSDWriter.data(width: w, height: h, layers: [.init(name: "Photo", rgb: original)], composite: original, iccProfile: icc)
        }

        let (foreground, alpha) = try foregroundPlanes(rgb, mask: mask, space: space)
        func byte(_ v: Float) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        // Where the subject is (even faintly) use its cleaned colours; elsewhere the original, so painting the mask
        // back in reveals the real scene.
        let subject = (0..<3).map { c in (0..<n).map { alpha[$0] > 0.01 ? byte(foreground[c][$0]) : original[c][$0] } }
        let matte = alpha.map(byte)
        let composite = (0..<3).map { c in (0..<n).map { byte(foreground[c][$0] * alpha[$0] + (1 - alpha[$0])) } }   // on white
        return PSDWriter.data(width: w, height: h, layers: [
            .init(name: "Original photo", rgb: original, hidden: true),
            .init(name: "Subject", rgb: subject, mask: matte),
        ], composite: composite, iccProfile: icc)
    }

    /// RGBA float pixels ⇄ four consecutive planes (vImage's "ARGB" naming is positional, so RGBA order works too).
    nonisolated private func convert(_ rgba: inout [Float], _ planar: inout [Float], width: Int, height: Int, toPlanar: Bool) throws {
        let n = width * height
        let status = rgba.withUnsafeMutableBytes { chunky in
            planar.withUnsafeMutableBufferPointer { planes in
                var interleaved = vImage_Buffer(data: chunky.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 16)
                var p = (0..<4).map {
                    vImage_Buffer(data: planes.baseAddress! + $0 * n, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                }
                return toPlanar
                    ? vImageConvert_ARGBFFFFtoPlanarF(&interleaved, &p[0], &p[1], &p[2], &p[3], vImage_Flags(kvImageNoFlags))
                    : vImageConvert_PlanarFtoARGBFFFF(&p[0], &p[1], &p[2], &p[3], &interleaved, vImage_Flags(kvImageNoFlags))
            }
        }
        guard status == kvImageNoError else { throw EngineError.render }
    }

    /// Splits an image that already has transparency into opaque colour + matte.
    nonisolated func split(_ image: CGImage) throws -> (rgb: CGImage, mask: CGImage?) {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return (image, nil)
        default: break
        }
        let space = workingSpace(image)
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let input = CIImage(cgImage: image)
        let alpha = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let opaque = input.unpremultiplyingAlpha().settingAlphaOne(in: extent)
        let format: CIFormat = image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        guard let rgb = context.createCGImage(opaque, from: extent, format: format, colorSpace: space),
              let mask = context.createCGImage(alpha, from: extent, format: .L8, colorSpace: linearGray)
        else { throw EngineError.render }
        return (rgb, mask)
    }

    /// Builds a layer with a screen-sized preview of the composite.
    nonisolated func makeLayer(rgb: CGImage, mask: CGImage?) throws -> Layer {
        let full = try composite(rgb, mask: mask)
        let longest = CGFloat(max(full.width, full.height))
        let scale = min(1, 3072 / longest)
        var preview = full
        if scale < 1 {
            let image = CIImage(cgImage: full).applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
            let extent = CGRect(x: 0, y: 0, width: Int(CGFloat(full.width) * scale), height: Int(CGFloat(full.height) * scale))
            guard let small = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: workingSpace(full)) else { throw EngineError.render }
            preview = small
        }
        return Layer(rgb: rgb, mask: mask, preview: preview)
    }
}
