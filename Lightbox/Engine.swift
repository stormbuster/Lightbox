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


nonisolated enum AIModel: String, CaseIterable, Identifiable, Sendable {
    case birefnetHR = "BiRefNet_HR_2048"
    case birefnetMatting = "BiRefNet_HR_Matting_2048"
    case nomosDAT2 = "Nomos2_DAT2_x4"
    case bhiDAT2 = "BHI_DAT2_Real_x4"
    case realESRGAN = "RealESRGAN_x4"

    static let cutout: [AIModel] = [.birefnetHR, .birefnetMatting]
    static let upscalers: [AIModel] = [.nomosDAT2, .bhiDAT2, .realESRGAN]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .birefnetHR: "BiRefNet HR"
        case .birefnetMatting: "BiRefNet HR Matting"
        case .nomosDAT2: "Faithful (Nomos2 DAT2)"
        case .bhiDAT2: "Restore (BHI DAT2)"
        case .realESRGAN: "Fast (Real-ESRGAN)"
        }
    }

    var detail: String {
        switch self {
        case .birefnetHR: "Crisp subject cutouts at 2048 px. Best for products, people, objects."
        case .birefnetMatting: "Soft alpha matte for hair, fur, veils and glass."
        case .nomosDAT2: "For clean camera originals (RAW, TIFF, high-quality JPEG). Adds detail without inventing texture."
        case .bhiDAT2: "For compressed, noisy or slightly soft photos: removes JPEG blocks and noise while upscaling."
        case .realESRGAN: "About 4× faster on the Neural Engine. Smoother, slightly painterly look."
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
        for id in [AIModel.birefnetHR, .bhiDAT2] {
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
    func matte(for rgb: CGImage, using id: AIModel) throws -> CGImage {
        let model = try model(id)
        let size = inputSize(of: model)
        let space = workingSpace(rgb)
        let input = try pixelBuffer(size)
        context.render(resample(rgb, to: size), to: input, bounds: CGRect(origin: .zero, size: size), colorSpace: space)

        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)]))
        guard let buffer = output.featureValue(for: "mask")?.imageBufferValue else { throw EngineError.noOutput }
        let small = context.createCGImage(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: linearGray]),
                                          from: CGRect(origin: .zero, size: size), format: .L8, colorSpace: linearGray)
        guard let small else { throw EngineError.render }
        return try resize(mask: small, to: CGSize(width: rgb.width, height: rgb.height))
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
        var image = CIImage(cgImage: rgb).applyingFilter("CIBlendWithRedMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: CIImage(cgImage: mask),
        ])
        if let background {
            image = image.composited(over: CIImage(color: CIColor(cgColor: background)).cropped(to: image.extent))
        }
        let format: CIFormat = rgb.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        guard let out = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: rgb.width, height: rgb.height),
                                              format: format, colorSpace: space) else { throw EngineError.render }
        return out
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
