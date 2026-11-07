import SwiftUI

@main
struct SnapFrameApp: App {
    @StateObject private var model = ImportModel()

    var body: some Scene {
        Window("SnapFrame", id: "main") {
            MainWindow(model: model)
        }
        .defaultSize(width: 960, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Image…") {
                    model.isFilePickerPresented = true
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.isImporting)

                Button("Remove Image") {
                    model.removeImage()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.image == nil || model.isImporting)
            }
        }
    }
}
