import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @ObservedObject var model: ImportModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ImageDropArea(
                isTargeted: $isDropTargeted,
                isEnabled: !model.isImporting,
                onDrop: model.importDroppedImages
            ) {
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)

                    if let image = model.image {
                        PreviewView(image: image)
                            .padding(32)
                    } else {
                        emptyState
                    }

                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(0.08))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                            }
                            .padding(16)
                            .allowsHitTesting(false)
                    }

                    if model.isImporting {
                        ProgressView("Opening image…")
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            statusBar
        }
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle(model.image?.filename ?? "SnapFrame")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.image != nil {
                    Button {
                        model.removeImage()
                    } label: {
                        Label("Remove Image", systemImage: "xmark")
                    }
                    .help("Remove image (⌘⌫)")
                    .disabled(model.isImporting)
                }
                Button {
                    model.isFilePickerPresented = true
                } label: {
                    Label("Open Image…", systemImage: "photo.badge.plus")
                }
                .help("Open image (⌘O)")
                .disabled(model.isImporting)
            }
        }
        .fileImporter(
            isPresented: $model.isFilePickerPresented,
            allowedContentTypes: ImageImportService.supportedContentTypes
        ) { result in
            switch result {
            case .success(let url): model.importImage(from: url)
            case .failure(let error): model.report(error)
            }
        }
        .alert(item: $model.failure) { failure in
            Alert(
                title: Text("Couldn’t Open Image"),
                message: Text(failure.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Beautify images from Finder")
                    .font(.title2.weight(.semibold))
                Text("Select up to 16 PNG or JPEG images in Finder, then choose Quick Actions → SnapFrame.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("If SnapFrame is missing, enable it in Quick Actions → Customize. You can also preview an original image here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Open Image…") {
                model.isFilePickerPresented = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isImporting)
            Text("PNG, JPEG, HEIC, TIFF, and other ImageIO image formats")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let image = model.image {
                Text("\(image.pixelWidth) × \(image.pixelHeight) px")
                    .monospacedDigit()
                Text(image.formatName)
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .file))
                Spacer(minLength: 16)
                Text("Original image")
            } else {
                Text("No image open")
                Spacer()
                Text("All files stay on your Mac")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(.bar)
    }
}
