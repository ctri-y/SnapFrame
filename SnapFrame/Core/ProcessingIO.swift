// Promoted from the verified P1.0 file-access prototype; original sources are retained.
import Darwin
import Foundation

enum ProcessingFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { text } else { "Processing failed" } }
}

/// Only this small cancellation flag crosses callback/worker queues. Its state is locked.
final class ProcessingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if isCancelled { throw CancellationError() } }
}

struct ProcessingWorkspace: Sendable {
    let id: String
    let root: URL
    private let lease: ProcessingWorkspaceLease
    var inputs: URL { root.appendingPathComponent("Inputs", isDirectory: true) }
    var outputs: URL { root.appendingPathComponent("Outputs", isDirectory: true) }

    static func create(base: URL? = nil) throws -> Self {
        let base = base ?? defaultBase
        let id = UUID().uuidString
        let root = base.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let lease = try ProcessingWorkspaceLease(url: root.appendingPathComponent(".lease"))
        let job = Self(id: id, root: root, lease: lease)
        try FileManager.default.createDirectory(at: job.inputs, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: job.outputs, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return job
    }

    private static var defaultBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnapFrame/Jobs", isDirectory: true)
    }

    /// A process exit releases flock. Another request may reclaim only an unlocked,
    /// UUID-named job in SnapFrame's private directory; active jobs are untouched.
    static func recoverAbandoned(base: URL? = nil) throws -> [String] {
        let base = base ?? defaultBase
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        var recovered: [String] = []
        for root in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard UUID(uuidString: root.lastPathComponent) != nil else { continue }
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let fd = open(root.appendingPathComponent(".lease").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { flock(fd, LOCK_UN); close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            try FileManager.default.removeItem(at: root)
            recovered.append(root.lastPathComponent)
        }
        return recovered.sorted()
    }

    func cleanup() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }
}

private final class ProcessingWorkspaceLease: @unchecked Sendable {
    private let descriptor: Int32
    init(url: URL) throws {
        descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw POSIXError(.EWOULDBLOCK)
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

enum ProcessingIO {
    static let maxInputBytes = 64 * 1024 * 1024

    /// Creates a new file exclusively; never truncates or follows a destination symlink.
    static func writeExclusive(_ data: Data, directory: URL, preferredName: String,
                               shouldCancel: () -> Bool = { false }) throws -> URL {
        let safeName = URL(fileURLWithPath: preferredName).lastPathComponent
        guard safeName != ".", safeName != "..", !safeName.isEmpty else {
            throw ProcessingFailure.invalid("Invalid output name")
        }
        var stem = (safeName as NSString).deletingPathExtension
        let suffix = (safeName as NSString).pathExtension
        let extensionBytes = suffix.isEmpty ? 0 : suffix.utf8.count + 1
        while !stem.isEmpty && stem.utf8.count + extensionBytes > 220 { stem.removeLast() }
        guard !stem.isEmpty else { throw ProcessingFailure.invalid("The output filename is too long.") }
        let firstName = stem + (suffix.isEmpty ? "" : "." + suffix)
        for index in 1...10_000 {
            if shouldCancel() { throw CancellationError() }
            let name = index == 1 ? firstName : "\(stem)-\(index)\(suffix.isEmpty ? "" : "." + suffix)"
            let url = directory.appendingPathComponent(name)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var completed = false
            defer {
                close(descriptor)
                if !completed { unlink(url.path) }
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    if shouldCancel() { throw CancellationError() }
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), min(64 * 1024, bytes.count - offset))
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    guard count > 0 else { throw POSIXError(.EIO) }
                    offset += count
                }
            }
            if fsync(descriptor) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            completed = true
            return url
        }
        throw ProcessingFailure.invalid("Output name allocation exhausted")
    }

    /// A bounded copy completes inside the NSItemProvider callback, before its URL expires.
    static func stage(_ source: URL, index: Int, workspace: ProcessingWorkspace, byteBudget: Int = maxInputBytes,
                      shouldCancel: () -> Bool) throws -> URL {
        guard source.isFileURL else { throw ProcessingFailure.invalid("Provider did not return a file URL") }
        let metadata = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard metadata.isRegularFile == true else { throw ProcessingFailure.invalid("Input is not a regular file") }
        guard let size = metadata.fileSize, size <= min(maxInputBytes, byteBudget) else {
            throw ProcessingFailure.invalid("Input exceeds the remaining batch byte budget")
        }
        if shouldCancel() { throw CancellationError() }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var bytes = Data()
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if shouldCancel() { throw CancellationError() }
            guard bytes.count + chunk.count <= min(maxInputBytes, byteBudget) else {
                throw ProcessingFailure.invalid("Input grew beyond the batch budget")
            }
            bytes.append(chunk)
        }
        return try writeExclusive(bytes, directory: workspace.inputs, preferredName: "\(index)-input.bin", shouldCancel: shouldCancel)
    }
}
