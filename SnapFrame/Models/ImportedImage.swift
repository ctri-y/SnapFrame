import CoreGraphics
import Foundation

/// A decoded original, with pixel dimensions independent of display/Retina scale.
struct ImportedImage: Sendable {
    let sourceURL: URL
    let cgImage: CGImage
    let formatName: String
    let byteCount: Int

    var filename: String { sourceURL.lastPathComponent }
    var pixelWidth: Int { cgImage.width }
    var pixelHeight: Int { cgImage.height }
}
