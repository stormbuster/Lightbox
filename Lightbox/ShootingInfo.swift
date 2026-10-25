//
//  ShootingInfo.swift
//  Lightbox
//
//  Camera, lens and exposure from EXIF, and what they imply for background removal:
//  depth of field decides how soft subject edges are (soft- vs crisp-edge model, how wide the hair refinement band is),
//  shutter speed hints at motion blur, and sensor-size-adjusted ISO at noise that hides fine hair.
//

import Foundation
import ImageIO


/// Parameters for `Engine.matte` derived from the shooting conditions.
nonisolated struct CutoutTuning: Sendable, Equatable {
    var model: AIModel = .birefnetMatting
    /// Multiplies the width of the band around the subject's edge that the native-resolution pass refines.
    var bandScale: Double = 1
    /// Noise reduction applied to the model's input only (never to the saved photo).
    var denoise = false
    var reasons: [String] = []

    static let standard = CutoutTuning()
}


nonisolated struct ShootingInfo: Sendable {
    var camera: String?
    var lens: String?
    var focalLength: Double?
    var focal35: Double?
    var aperture: Double?
    var exposure: Double?
    var iso: Double?
    var cropFactor: Double

    init?(_ metadata: PhotoMetadata?) {
        guard let props = metadata?.properties else { return nil }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        camera = model.map { m in make.map { m.lowercased().hasPrefix($0.lowercased().split(separator: " ").first.map(String.init) ?? $0.lowercased()) ? m : "\($0) \(m)" } ?? m }
        lens = (exif[kCGImagePropertyExifLensModel] as? String)?.trimmingCharacters(in: .whitespaces)
        focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
        focal35 = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue
        aperture = exif[kCGImagePropertyExifFNumber] as? Double
        exposure = exif[kCGImagePropertyExifExposureTime] as? Double
        iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.doubleValue
        if let f = focalLength, let f35 = focal35, f > 0, f35 > 0 {
            cropFactor = f35 / f
        } else {
            cropFactor = Self.cropFactor(make: make ?? "", model: model ?? "")
        }
        if focal35 == nil, let f = focalLength { focal35 = f * cropFactor }
        guard camera != nil || aperture != nil || focalLength != nil else { return nil }
    }

    var summary: String {
        var parts: [String] = []
        if let camera { parts.append(camera) }
        if let lens, let f = focalLength { parts.append("\(lens) at \(Int(f.rounded())) mm") }
        else if let f = focalLength { parts.append("\(Int(f.rounded())) mm") }
        if let n = aperture { parts.append("f/\(n.formatted(.number.precision(.fractionLength(0...1))))") }
        if let t = exposure { parts.append(t >= 1 ? "\(t.formatted()) s" : "1/\(Int((1 / t).rounded())) s") }
        if let iso { parts.append("ISO \(Int(iso))") }
        return parts.joined(separator: " · ")
    }

    var tuning: CutoutTuning {
        var t = CutoutTuning()
        // Background blur grows with focal length² / aperture, judged on the 35 mm-equivalent aperture.
        if let f35 = focal35, let n = aperture, n > 0 {
            let blur = f35 * f35 / (n * cropFactor)
            if blur >= 800 {
                t.model = .birefnetMatting; t.bandScale = 1.5
                t.reasons.append("shallow depth of field: soft edges, wider hair refinement")
            } else if blur < 200 {
                t.model = .birefnetHR; t.bandScale = 0.75
                t.reasons.append("deep focus: crisp edges")
            } else {
                t.reasons.append("moderate depth of field")
            }
        }
        // Slower than ~1/focal length (35 mm equiv.) risks motion blur on people.
        if let s = exposure, let f35 = focal35, s > 1 / max(f35, 30) {
            t.model = .birefnetMatting; t.bandScale = max(t.bandScale, 1.25)
            t.reasons.append("slow shutter: allows for motion blur")
        }
        // Noise scales with sensor area: compare ISO × crop² against a full-frame threshold.
        if let iso, iso * cropFactor * cropFactor >= 6400 {
            t.denoise = true
            t.reasons.append("high noise: model input is denoised")
        }
        return t
    }

    /// Sensor size by body when EXIF has no 35 mm-equivalent focal length.
    private static func cropFactor(make: String, model: String) -> Double {
        let m = model.uppercased(), k = make.uppercased()
        func any(_ needles: [String]) -> Bool { needles.contains { m.contains($0) } }
        if k.contains("CANON") {
            return any(["5D", "6D", "1D", "EOS R5", "EOS R6", "EOS R8", "EOS R3", "EOS R1", "EOS RP"]) || m.hasSuffix("EOS R") ? 1 : 1.6
        }
        if k.contains("NIKON") {
            return any(["Z 5", "Z 6", "Z 7", "Z 8", "Z 9", "Z F", "D3", "D4", "D5", "D6", "D600", "D610", "D700", "D750", "D780", "D800", "D810", "D850", "DF"]) ? 1 : 1.5
        }
        if k.contains("SONY") { return any(["ILCE-7", "ILCE-9", "ILCE-1", "DSC-RX1"]) ? 1 : any(["RX100"]) ? 2.7 : 1.5 }
        if k.contains("FUJI") { return m.contains("GFX") ? 0.79 : 1.5 }
        if k.contains("OLYMPUS") || k.contains("OM DIGITAL") { return 2 }
        if k.contains("PANASONIC") { return m.contains("DC-S") ? 1 : 2 }
        if k.contains("LEICA") || k.contains("HASSELBLAD") { return 1 }
        return 1.5
    }
}
