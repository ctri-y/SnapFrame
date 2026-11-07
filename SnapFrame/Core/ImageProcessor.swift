import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pixel-only rendering: no windows, file access or Finder dependencies.
enum ImageProcessor {
    static let padding = 140
    static let cornerRadius: CGFloat = 24
    static let shadowBlur: CGFloat = 64
    static let shadowOffsetX: CGFloat = 12
    static let shadowOffset: CGFloat = 48
    static let shadowOpacity: CGFloat = 0.42
    static let maxInputPixels = 16_777_216
    static let maxOutputPixels = 20_000_000

    static func canvasSize(width: Int, height: Int) throws -> (width: Int, height: Int) {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= maxInputPixels / height else {
            throw ProcessingFailure.invalid("This image is too large. Use an image up to 16 megapixels and 16,384 pixels per side.")
        }
        let outputWidth = width + padding * 2, outputHeight = height + padding * 2
        guard outputWidth <= maxOutputPixels / outputHeight else {
            throw ProcessingFailure.invalid("The output canvas is too large.")
        }
        return (outputWidth, outputHeight)
    }

    static func render(_ source: CGImage) throws -> CGImage {
        let size = try canvasSize(width: source.width, height: source.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        func context(width: Int, height: Int) throws -> CGContext {
            guard let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ProcessingFailure.invalid("Not enough memory to render this image.")
            }
            context.interpolationQuality = .none
            return context
        }

        let content = try context(width: source.width, height: source.height)
        let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let radius = min(cornerRadius, CGFloat(min(source.width, source.height)) / 2)
        content.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        content.clip()
        content.draw(source, in: rect)
        guard let rounded = content.makeImage() else {
            throw ProcessingFailure.invalid("Could not create the rounded image.")
        }

        let canvas = try context(width: size.width, height: size.height)
        // Light comes from the upper left. Quartz is y-up, so the cast shadow
        // moves right and down; the smaller blur keeps the upper halo light.
        canvas.setShadow(offset: CGSize(width: shadowOffsetX, height: -shadowOffset), blur: shadowBlur,
                         color: CGColor(gray: 0, alpha: shadowOpacity))
        canvas.draw(rounded, in: rect.offsetBy(dx: CGFloat(padding), dy: CGFloat(padding)))
        guard let result = canvas.makeImage() else {
            throw ProcessingFailure.invalid("Could not create the output image.")
        }
        return result
    }

    static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ProcessingFailure.invalid("Could not create a PNG encoder.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ProcessingFailure.invalid("Could not encode the PNG.")
        }
        return data as Data
    }
}
