import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A small serial batch: one decoded image at a time, independent per-file errors.
enum BatchJobRunner {
    struct Input: Sendable {
        let url: URL
        let name: String
    }

    struct Failure: Sendable {
        let name: String
        let message: String
    }

    struct Result: Sendable {
        var outputs: [URL] = []
        var failures: [Failure] = []
    }

    static func run(_ inputs: [Input], outputDirectory: URL, cancellation: ProcessingCancellation,
                    progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> Result {
        guard (1...16).contains(inputs.count) else {
            throw ProcessingFailure.invalid("Select between 1 and 16 PNG or JPEG images.")
        }
        var result = Result()
        var outputBytes = 0
        for (index, input) in inputs.enumerated() {
            try cancellation.check()
            progress(index + 1, inputs.count)
            do {
                let output = try autoreleasepool {
                    let metadata = try input.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard metadata.isRegularFile == true, let bytes = metadata.fileSize,
                          bytes <= ProcessingIO.maxInputBytes else {
                        throw ProcessingFailure.invalid("Use a local PNG or JPEG file up to 64 MiB.")
                    }
                    guard let source = CGImageSourceCreateWithURL(input.url as CFURL, nil),
                          let type = CGImageSourceGetType(source) as String?,
                          [UTType.png.identifier, UTType.jpeg.identifier].contains(type),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                        throw ProcessingFailure.invalid("This file could not be read as a PNG or JPEG image.")
                    }
                    _ = try ImageProcessor.canvasSize(width: width, height: height)
                    let imported = try ImageImportService.load(from: input.url)
                    try cancellation.check()
                    let rendered = try ImageProcessor.render(imported.cgImage)
                    try cancellation.check()
                    let data = try ImageProcessor.pngData(rendered)
                    guard data.count <= 256 * 1024 * 1024 - outputBytes else {
                        throw ProcessingFailure.invalid("The batch output is too large. Try fewer images.")
                    }
                    let stem = (input.name as NSString).deletingPathExtension
                    let url = try ProcessingIO.writeExclusive(data, directory: outputDirectory,
                        preferredName: "\(stem) SnapFrame.png", shouldCancel: { cancellation.isCancelled })
                    outputBytes += data.count
                    return url
                }
                result.outputs.append(output)
            } catch {
                try cancellation.check()
                result.failures.append(Failure(name: input.name, message: error.localizedDescription))
            }
        }
        try cancellation.check()
        return result
    }
}
