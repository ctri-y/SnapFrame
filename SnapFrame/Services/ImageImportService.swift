import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Read-only import. No processing, source mutation, or persistent file access.
enum ImageImportService {
    /// Use the actual installed decoders, including on systems with incomplete UTI ancestry.
    static var supportedContentTypes: [UTType] {
        (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).compactMap { UTType($0) }
    }

    static func load(from url: URL) throws -> ImportedImage {
        guard url.isFileURL else { throw ImageImportError.localFilesOnly }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw ImageImportError.notAFile }
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String),
              CGImageSourceGetCount(source) > 0 else {
            throw ImageImportError.unsupportedImage
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let cgImage: CGImage?
        if orientation == 1 {
            // Keep original pixels and embedded color space; do not resize to screen points.
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        } else {
            // ImageIO applies EXIF rotation/mirroring at the original pixel resolution.
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard max(width, height) > 0 else { throw ImageImportError.unsupportedImage }
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }

        guard let cgImage, cgImage.width > 0, cgImage.height > 0 else {
            throw ImageImportError.unsupportedImage
        }
        return ImportedImage(
            sourceURL: url,
            cgImage: cgImage,
            formatName: formatName(for: type),
            byteCount: data.count
        )
    }

    private static func formatName(for type: UTType) -> String {
        switch type.identifier {
        case UTType.png.identifier: "PNG"
        case UTType.jpeg.identifier: "JPEG"
        case UTType.tiff.identifier: "TIFF"
        case UTType.heic.identifier: "HEIC"
        case UTType.gif.identifier: "GIF · first frame"
        default: type.localizedDescription ?? type.identifier
        }
    }
}

enum ImageImportError: LocalizedError {
    case localFilesOnly
    case notAFile
    case unsupportedImage

    var errorDescription: String? {
        switch self {
        case .localFilesOnly:
            "Choose an image stored on this Mac. Remote URLs are not supported."
        case .notAFile:
            "Choose an image file rather than a folder."
        case .unsupportedImage:
            "This file could not be decoded as an image. Try a PNG, JPEG, HEIC, or TIFF file."
        }
    }
}
