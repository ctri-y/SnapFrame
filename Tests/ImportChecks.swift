import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// Dependency-free integration checks, runnable with Apple's Command Line Tools.
@main
struct ImportChecks {
    @MainActor
    static func main() async throws {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let png = fixtures.appendingPathComponent("Transparent.png")
        let jpeg = fixtures.appendingPathComponent("Landscape.jpg")
        let rotated = fixtures.appendingPathComponent("Rotated.jpg")
        let retina = fixtures.appendingPathComponent("Retina.tiff")
        let corrupt = fixtures.appendingPathComponent("Corrupt.png")
        let disguised = fixtures.appendingPathComponent("Image-without-extension")
        let width = 1200, height = 720
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.12, green: 0.40, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 80, y: 80, width: 1040, height: 560))
        context.setFillColor(CGColor(red: 0.60, green: 0.85, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 120, y: 120, width: 960, height: 48))
        context.fill(CGRect(x: 120, y: 520, width: 320, height: 80))
        let original = context.makeImage()!

        try write(original, to: png, type: .png)
        try write(original, to: jpeg, type: .jpeg)
        try write(original, to: rotated, type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        try write(original, to: retina, type: .tiff, properties: [
            kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144
        ])
        try Data("This is not an image".utf8).write(to: corrupt)
        try Data(contentsOf: png).write(to: disguised)

        let before = try Data(contentsOf: png)
        let loadedPNG = try ImageImportService.load(from: png)
        try check(loadedPNG.pixelWidth == width && loadedPNG.pixelHeight == height, "PNG pixel dimensions")
        try check(loadedPNG.cgImage.alphaInfo != .none && loadedPNG.cgImage.alphaInfo != .noneSkipLast, "PNG alpha retained")
        try check(loadedPNG.cgImage.colorSpace?.name == CGColorSpace.sRGB, "Embedded sRGB color space retained")
        try check(try Data(contentsOf: png) == before, "Source bytes unchanged")
        let loadedJPEG = try ImageImportService.load(from: jpeg)
        try check(loadedJPEG.pixelWidth == width && loadedJPEG.pixelHeight == height, "JPEG decoding")
        let loadedRotated = try ImageImportService.load(from: rotated)
        try check(loadedRotated.pixelWidth == height && loadedRotated.pixelHeight == width, "EXIF orientation applied")
        let loadedRetina = try ImageImportService.load(from: retina)
        try check(loadedRetina.pixelWidth == width && loadedRetina.pixelHeight == height, "144-DPI TIFF keeps pixel dimensions")
        let loadedDisguised = try ImageImportService.load(from: disguised)
        try check(loadedDisguised.pixelWidth == width, "Image identified by content")
        try expectFailure("Corrupt image rejected") { _ = try ImageImportService.load(from: corrupt) }
        try expectFailure("Folder rejected") { _ = try ImageImportService.load(from: fixtures) }
        try expectFailure("Missing file rejected") { _ = try ImageImportService.load(from: fixtures.appendingPathComponent("Missing.png")) }
        try expectFailure("Remote URL rejected") { _ = try ImageImportService.load(from: URL(string: "https://example.com/image.png")!) }

        let model = ImportModel()
        model.report(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        try check(model.failure == nil, "Picker cancellation is silent")
        model.importImage(from: png)
        try await waitForImport(model)
        try check(model.image?.filename == png.lastPathComponent && !model.isImporting, "Asynchronous model import")
        model.importImage(from: corrupt)
        try await waitForImport(model)
        try check(model.failure != nil && model.image?.filename == png.lastPathComponent, "Failed import preserves current image")
        model.failure = nil
        try check(!model.importDroppedImages([png, jpeg]) && model.failure != nil, "Multiple-file drop rejected explicitly")
        model.removeImage()
        try check(model.image == nil, "Remove returns to empty state")
        model.failure = nil
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.writeObjects([png as NSURL]) else {
            throw CheckFailure(message: "macOS pasteboard service is unavailable. Run these native checks in a normal GUI login session.")
        }
        let droppedURLs = FileDropReader.urls(from: pasteboard)
        try check(droppedURLs == [png], "Native Finder file pasteboard resolves URL")
        try check(model.importDroppedImages(droppedURLs), "Native file drop accepted")
        try await waitForImport(model)
        try check(model.image?.filename == png.lastPathComponent && model.failure == nil, "Native file drop loads asynchronously")
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("https://example.com/image.png", forType: .fileURL)
        pasteboard.writeObjects([item])
        try check(FileDropReader.urls(from: pasteboard).isEmpty, "Remote URL disguised as file drop rejected")
        print("All 21 P0 import checks passed. Fixtures: \(fixtures.path)")
    }

    @MainActor
    static func waitForImport(_ model: ImportModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isImporting {
            guard ContinuousClock.now < deadline else { throw CheckFailure(message: "Import timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw CheckFailure(message: label) }
        print("PASS: \(label)")
    }

    static func expectFailure(_ label: String, operation: () throws -> Void) throws {
        do { try operation() } catch { print("PASS: \(label)"); return }
        throw CheckFailure(message: label)
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CheckFailure(message: "Create fixture \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CheckFailure(message: "Write fixture \(url.lastPathComponent)")
        }
    }
}

struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
