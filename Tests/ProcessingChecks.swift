import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main enum ProcessingChecks {
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw ProcessingFailure.invalid(message) }
        print("PASS: \(message)")
    }

    static func fixture(width: Int, height: Int, alpha: Bool = false, space: CGColorSpace? = nil) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !alpha {
            context.setFillColor(CGColor(red: 0.16, green: 0.32, blue: 0.72, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.setFillColor(CGColor(red: 0.9, green: 0.35, blue: 0.15, alpha: alpha ? 0.6 : 1))
        context.fill(CGRect(x: width / 8, y: height / 8, width: width / 2, height: height / 3))
        context.setFillColor(CGColor(red: 0.3, green: 0.85, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: width / 8, y: height * 3 / 4, width: width * 3 / 4, height: max(1, height / 12)))
        return context.makeImage()!
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    static func write(_ image: CGImage, _ url: URL, type: UTType = .png) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        try check(CGImageDestinationFinalize(destination), "Write \(url.lastPathComponent)")
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let build = root.appendingPathComponent(".build/MVP/Checks")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let input = fixture(width: 320, height: 200)
        let output = try ImageProcessor.render(input)
        try check(output.width == 600 && output.height == 480, "Original pixel size plus 140-pixel transparent margins")
        let bytes = pixels(output), original = pixels(input), pad = ImageProcessor.padding
        let alpha: (Int, Int) -> Int = { x, y in Int(bytes[(y * output.width + x) * 4 + 3]) }
        try check(alpha(pad + 160, pad + 100) == 255, "Opaque content remains opaque")
        try check(alpha(pad, pad) < 100 && alpha(pad + 24, pad + 24) == 255, "Corners are rounded rather than rectangular")
        var borderClear = true
        for x in 0..<output.width { borderClear = borderClear && alpha(x, 0) == 0 && alpha(x, output.height - 1) == 0 }
        for y in 0..<output.height { borderClear = borderClear && alpha(0, y) == 0 && alpha(output.width - 1, y) == 0 }
        try check(borderClear, "Outer border is fully transparent; shadow is not clipped")
        var topShadow = 0, bottomShadow = 0, intermediateAlpha = false
        for y in 0..<pad {
            for x in pad..<(pad + input.width) {
                topShadow += alpha(x, y)
                bottomShadow += alpha(x, output.height - 1 - y)
                intermediateAlpha = intermediateAlpha || (1..<90).contains(alpha(x, y))
            }
        }
        try check(bottomShadow > topShadow && topShadow > 0 && intermediateAlpha, "Soft shadow extends below the image with a gradual alpha falloff")
        try check(bottomShadow > topShadow * 8, "Directional lighting leaves a light upper halo and a substantially heavier bottom shadow")
        var leftShadow = 0, rightShadow = 0
        for x in 0..<pad {
            for y in pad..<(pad + input.height) {
                leftShadow += alpha(x, y)
                rightShadow += alpha(output.width - 1 - x, y)
            }
        }
        try check(rightShadow * 2 > leftShadow * 3, "Upper-left lighting casts more shadow on the right than the left")
        var centersMatch = true
        for y in 30..<(input.height - 30) {
            for x in 30..<(input.width - 30) {
                let a = (y * input.width + x) * 4, b = ((y + pad) * output.width + x + pad) * 4
                centersMatch = centersMatch && original[a..<a+4].elementsEqual(bytes[b..<b+4])
            }
        }
        try check(centersMatch, "Interior pixels keep their color, orientation and resolution")
        let transparent = try ImageProcessor.render(fixture(width: 320, height: 200, alpha: true))
        let transparentPixels = pixels(transparent)
        try check(transparentPixels[((pad + 50) * transparent.width + pad + 250) * 4 + 3] < 100, "Transparent input does not gain an opaque background")
        let tiny = try ImageProcessor.render(fixture(width: 4, height: 4))
        try check(tiny.width == 284 && tiny.height == 284, "Small images clamp the corner radius safely")
        let p3 = try ImageProcessor.render(fixture(width: 40, height: 40, space: CGColorSpace(name: CGColorSpace.displayP3)))
        try check(p3.colorSpace?.name == CGColorSpace.sRGB, "Display P3 input is converted to the MVP's explicit sRGB output")
        do {
            _ = try ImageProcessor.canvasSize(width: 100_000, height: 100_000)
            throw ProcessingFailure.invalid("Oversized canvas accepted")
        } catch ProcessingFailure.invalid(let message) {
            try check(message.contains("large"), "Oversized dimensions are rejected before allocating pixels")
        }
        let png = try ImageProcessor.pngData(output)
        let decodedSource = CGImageSourceCreateWithData(png as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(decodedSource, 0, nil)!
        try check(CGImageSourceGetType(decodedSource) as String? == UTType.png.identifier && pixels(decoded) == bytes,
                  "PNG export round-trips all color and alpha pixels")
        try png.write(to: build.appendingPathComponent("Preview.png"))
        let preview = CGContext(data: nil, width: output.width, height: output.height, bitsPerComponent: 8,
            bytesPerRow: output.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        preview.setFillColor(CGColor(gray: 1, alpha: 1))
        preview.fill(CGRect(x: 0, y: 0, width: output.width, height: output.height))
        preview.draw(output, in: CGRect(x: 0, y: 0, width: output.width, height: output.height))
        try ImageProcessor.pngData(preview.makeImage()!).write(to: build.appendingPathComponent("PreviewOnWhite.png"))

        let goldenDirectory = root.appendingPathComponent("Tests/Golden")
        if CommandLine.arguments.contains("--record-golden") {
            try FileManager.default.createDirectory(at: goldenDirectory, withIntermediateDirectories: true)
            try png.write(to: goldenDirectory.appendingPathComponent("Default.png"))
            try ImageProcessor.pngData(transparent).write(to: goldenDirectory.appendingPathComponent("Transparent.png"))
        } else {
            for (name, rendered) in [("Default.png", output), ("Transparent.png", transparent)] {
                let source = CGImageSourceCreateWithURL(goldenDirectory.appendingPathComponent(name) as CFURL, nil)!
                let reference = CGImageSourceCreateImageAtIndex(source, 0, nil)!
                try check(reference.width == rendered.width && reference.height == rendered.height && pixels(reference) == pixels(rendered),
                          "Golden image: \(name)")
            }
        }

        let sources = build.appendingPathComponent("Sources"), exports = build.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let a = sources.appendingPathComponent("Same.png"), b = sources.appendingPathComponent("Same.jpg"), bad = sources.appendingPathComponent("Broken.png")
        try write(input, a); try write(input, b, type: .jpeg)
        try Data("Not an image".utf8).write(to: bad)
        let originals = try [a, b, bad].map { try Data(contentsOf: $0) }
        let sentinel = exports.appendingPathComponent("Same SnapFrame.png")
        try Data("existing file".utf8).write(to: sentinel)
        let inputs = [a, bad, b].map { BatchJobRunner.Input(url: $0, name: $0.lastPathComponent) }
        let result = try BatchJobRunner.run(inputs, outputDirectory: exports, cancellation: ProcessingCancellation())
        try check(result.outputs.count == 2 && result.failures.count == 1 && result.failures[0].name == "Broken.png",
                  "Bad PNG fails independently while PNG and JPEG both finish")
        try check(Set(result.outputs.map(\.lastPathComponent)).count == 2 && (try Data(contentsOf: sentinel)) == Data("existing file".utf8),
                  "Same-stem inputs and existing destination are never overwritten")
        try check(try [a, b, bad].enumerated().allSatisfy { try Data(contentsOf: $0.element) == originals[$0.offset] },
                  "Original PNG, JPEG and invalid input bytes are unchanged")
        for url in result.outputs {
            let image = try ImageImportService.load(from: url)
            try check(image.pixelWidth == 600 && image.pixelHeight == 480 && image.formatName == "PNG", "Batch output decodes: \(url.lastPathComponent)")
        }
        let longName = String(repeating: "界", count: 70) + ".png"
        let longResult = try BatchJobRunner.run([.init(url: a, name: longName)], outputDirectory: exports,
                                               cancellation: ProcessingCancellation())
        try check(longResult.outputs.count == 1 && longResult.outputs[0].pathExtension == "png"
                  && longResult.outputs[0].lastPathComponent.utf8.count <= 220,
                  "Long Unicode names keep a valid PNG extension")
        let sixteen = (0..<16).map { BatchJobRunner.Input(url: $0.isMultiple(of: 2) ? a : b, name: "Image-\($0).png") }
        let batch = try BatchJobRunner.run(sixteen, outputDirectory: exports, cancellation: ProcessingCancellation())
        try check(batch.outputs.count == 16 && batch.failures.isEmpty, "Sixteen mixed PNG/JPEG inputs finish serially")
        let workspace = try ProcessingWorkspace.create(base: build.appendingPathComponent("CancelJobs"))
        let cancelled = ProcessingCancellation()
        do {
            _ = try BatchJobRunner.run(sixteen, outputDirectory: workspace.outputs, cancellation: cancelled) { current, _ in
                if current == 2 { cancelled.cancel() }
            }
            throw ProcessingFailure.invalid("Cancellation ignored")
        } catch is CancellationError {}
        try workspace.cleanup()
        try check(!FileManager.default.fileExists(atPath: workspace.root.path) && (try Data(contentsOf: a)) == originals[0],
                  "Cancellation cleans only the owned job and keeps the original")
        for (width, height) in [(1920, 1080), (3840, 2160)] {
            try autoreleasepool {
                let image = fixture(width: width, height: height)
                let start = ContinuousClock.now
                let rendered = try ImageProcessor.render(image)
                let data = try ImageProcessor.pngData(rendered)
                let duration = start.duration(to: .now)
                print("TIMING: \(width)×\(height): \(duration); PNG \(data.count) bytes")
            }
        }
        print("All MVP processing checks passed.")
    }
}
