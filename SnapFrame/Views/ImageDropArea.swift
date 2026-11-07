import AppKit
import OSLog
import SwiftUI

/// A narrow AppKit boundary for real Finder drags; all visible content remains SwiftUI.
struct ImageDropArea<Content: View>: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let isEnabled: Bool
    let onDrop: ([URL]) -> Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> FileDropHostingView<Content> {
        let view = FileDropHostingView(rootView: content())
        configure(view)
        return view
    }

    func updateNSView(_ view: FileDropHostingView<Content>, context: Context) {
        view.rootView = content()
        configure(view)
    }

    private func configure(_ view: FileDropHostingView<Content>) {
        view.isDropEnabled = isEnabled
        view.onDrop = onDrop
        view.onTargetChange = { targeted in
            if isTargeted != targeted { isTargeted = targeted }
        }
    }
}

final class FileDropHostingView<Content: View>: NSHostingView<Content> {
    var isDropEnabled = true
    var onDrop: (([URL]) -> Bool)?
    var onTargetChange: ((Bool) -> Void)?
    private let logger = Logger(subsystem: "local.snapframe.app", category: "FileDrop")

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        logger.debug("Native file drag entered")
        return updateTarget(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onTargetChange?(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropEnabled && !FileDropReader.urls(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onTargetChange?(false)
        guard isDropEnabled else { return false }
        let urls = FileDropReader.urls(from: sender.draggingPasteboard)
        logger.debug("Native file drop received: \(urls.count) item(s)")
        return onDrop?(urls) ?? false
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        onTargetChange?(false)
    }

    private func updateTarget(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let canAccept = isDropEnabled && !FileDropReader.urls(from: sender.draggingPasteboard).isEmpty
        onTargetChange?(canAccept)
        return canAccept ? .copy : []
    }
}
