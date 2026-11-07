import SwiftUI

struct PreviewView: View {
    let image: ImportedImage

    var body: some View {
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / CGFloat(image.pixelWidth),
                geometry.size.height / CGFloat(image.pixelHeight),
                1
            )
            let width = CGFloat(image.pixelWidth) * scale
            let height = CGFloat(image.pixelHeight) * scale

            Image(image.cgImage, scale: 1, label: Text("Preview of \(image.filename)"))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: width, height: height)
                .background { TransparencyGrid() }
                .accessibilityLabel("Preview of \(image.filename), \(image.pixelWidth) by \(image.pixelHeight) pixels")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Preview-only checkerboard; it is never composited into the imported image.
private struct TransparencyGrid: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 10
            let base = colorScheme == .dark ? Color(white: 0.20) : Color(white: 0.96)
            let alternate = colorScheme == .dark ? Color(white: 0.25) : Color(white: 0.89)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
            for row in 0..<Int(ceil(size.height / tile)) {
                for column in 0..<Int(ceil(size.width / tile)) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)
                    context.fill(Path(rect), with: .color(alternate))
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
