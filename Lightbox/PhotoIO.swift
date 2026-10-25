//
//  PhotoIO.swift
//  Lightbox
//
//  Reading and writing photos with ImageIO, keeping the camera metadata.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers


nonisolated enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case png = "PNG", tiff = "TIFF", jpeg = "JPEG", heic = "HEIC"

    var id: String { rawValue }

    var type: UTType {
        switch self {
        case .png: .png
        case .tiff: .tiff
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }

    var supportsAlpha: Bool { self == .png || self == .tiff || self == .heic }
}


/// Source metadata (EXIF, GPS, IPTC, TIFF …) carried over to exports.
nonisolated struct PhotoMetadata: @unchecked Sendable {
    let properties: [CFString: Any]
}


nonisolated enum PhotoIO {
    enum Failure: LocalizedError {
        case unreadable(String), unwritable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Could not read “\(name)” as an image."
            case .unwritable(let name): "Could not write “\(name)”."
            }
        }
    }

    /// Full-resolution image with its EXIF orientation applied (RAW files use the system's default rendering).
    static func load(_ url: URL) throws -> (image: CGImage, metadata: PhotoMetadata) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { throw Failure.unreadable(url.lastPathComponent) }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw Failure.unreadable(url.lastPathComponent) }
        return (image, PhotoMetadata(properties: props))
    }

    static func write(_ image: CGImage, to url: URL, format: ExportFormat, metadata: PhotoMetadata?) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil)
        else { throw Failure.unwritable(url.lastPathComponent) }

        var props: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyExifAuxDictionary] {
            if let value = metadata?.properties[key] { props[key] = value }
        }
        // Pixels are already upright and resized: drop the old orientation and dimensions.
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            props[kCGImagePropertyExifDictionary] = exif
        }
        props[kCGImagePropertyOrientation] = 1
        if format == .jpeg || format == .heic {
            props[kCGImageDestinationLossyCompressionQuality] = 0.95
        }
        if format == .tiff {
            props[kCGImagePropertyTIFFDictionary] = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:])
                .merging([kCGImagePropertyTIFFCompression: 5]) { $1 }   // LZW
        }

        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable(url.lastPathComponent) }
    }
}
