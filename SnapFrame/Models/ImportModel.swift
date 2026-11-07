import Foundation
import SwiftUI

@MainActor
final class ImportModel: ObservableObject {
    @Published private(set) var image: ImportedImage?
    @Published private(set) var isImporting = false
    @Published var isFilePickerPresented = false
    @Published var failure: ImportFailure?

    func importImage(from url: URL) {
        guard !isImporting else { return }
        isImporting = true

        Task {
            defer { isImporting = false }
            do {
                // File access and decoding must not block the main UI thread.
                let imported = try await Task.detached(priority: .userInitiated) {
                    try ImageImportService.load(from: url)
                }.value
                image = imported
            } catch {
                report(error)
            }
        }
    }

    func importDroppedImages(_ urls: [URL]) -> Bool {
        guard !isImporting, !urls.isEmpty else { return false }
        guard urls.count == 1 else {
            failure = ImportFailure(message: "Please drop one image at a time. Batch import is planned for a later milestone.")
            return false
        }
        importImage(from: urls[0])
        return true
    }

    func removeImage() {
        guard !isImporting else { return }
        image = nil
    }

    func report(_ error: Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else { return }
        failure = ImportFailure(message: error.localizedDescription)
    }
}

struct ImportFailure: Identifiable {
    let id = UUID()
    let message: String
}
