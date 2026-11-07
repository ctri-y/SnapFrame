import AppKit

/// Finder supplies file URLs on the drag pasteboard. Read them while the drag is valid.
@MainActor
enum FileDropReader {
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        // AppKit resolves file-reference URLs and consumes the drag's sandbox extension.
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !objects.isEmpty { return objects.filter(\.isFileURL) }

        // Exact-type fallback avoids relying on a file-URL's UTI parent declarations.
        return (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard let string = item.string(forType: .fileURL),
                  let url = URL(string: string), url.isFileURL else { return nil }
            return (url as NSURL).filePathURL ?? url
        }
    }
}
