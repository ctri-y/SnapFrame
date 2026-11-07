import AppKit
import UniformTypeIdentifiers

// The callback gate and transfer/cleanup rules are retained from the P1.0 prototype.
private final class ProviderLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BatchJobRunner.Input, Error>?
    private var result: Result<BatchJobRunner.Input, Error>?
    private var progress: Progress?
    var finished: Bool { lock.withLock { result != nil } }

    func install(_ value: CheckedContinuation<BatchJobRunner.Input, Error>) {
        let existing: Result<BatchJobRunner.Input, Error>? = lock.withLock {
            if let result { return result }
            continuation = value
            return nil
        }
        if let existing { value.resume(with: existing) }
    }

    func attach(_ value: Progress) {
        let finished = lock.withLock { progress = value; return result != nil }
        if finished { value.cancel() }
    }

    func finish(_ value: Result<BatchJobRunner.Input, Error>) {
        let target = lock.withLock { () -> CheckedContinuation<BatchJobRunner.Input, Error>? in
            guard result == nil else { return nil }
            result = value
            let target = continuation
            continuation = nil
            progress = nil
            return target
        }
        target?.resume(with: value)
    }

    func cancel(error: Error = CancellationError()) {
        let active = lock.withLock { progress }
        active?.cancel()
        finish(.failure(error))
    }
}

@MainActor enum ActionInputAccess {
    static func stage(_ provider: NSItemProvider, index: Int, workspace: ProcessingWorkspace,
                      cancellation: ProcessingCancellation, byteBudget: Int) async throws -> BatchJobRunner.Input {
        let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
            ?? UTType.image.identifier
        let suggested = provider.suggestedName
        let gate = ProviderLoadGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let progress = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    guard !gate.finished else { return }
                    gate.finish(Result {
                        try cancellation.check()
                        if let error { throw error }
                        guard let url else { throw ProcessingFailure.invalid("Finder did not provide a readable file.") }
                        let scope = url.startAccessingSecurityScopedResource()
                        defer { if scope { url.stopAccessingSecurityScopedResource() } }
                        // Copy before returning from the callback; Finder's temporary URL expires.
                        let copy = try ProcessingIO.stage(url, index: index, workspace: workspace,
                            byteBudget: byteBudget, shouldCancel: { cancellation.isCancelled || gate.finished })
                        let name = suggested?.isEmpty == false ? suggested! : url.lastPathComponent
                        return BatchJobRunner.Input(url: copy, name: name)
                    })
                }
                gate.attach(progress)
                DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                    gate.cancel(error: ProcessingFailure.invalid("Finder took too long to provide this image. Try again after downloading it locally."))
                }
            }
        } onCancel: { gate.cancel() }
    }
}

final class ActionDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let workspace: ProcessingWorkspace
    private let outputs: [URL]
    private var vended = Set<Int>()
    private var completed = false
    private var cleanupStarted = false

    init(workspace: ProcessingWorkspace, outputs: [URL]) {
        self.workspace = workspace
        self.outputs = outputs
    }

    func didVend(_ index: Int) {
        lock.withLock { _ = vended.insert(index) }
        cleanupIfReady()
    }

    func didComplete() {
        lock.withLock { completed = true }
        cleanupIfReady()
    }

    private func cleanupIfReady() {
        let ready = lock.withLock {
            guard !cleanupStarted, completed, vended.count == outputs.count else { return false }
            cleanupStarted = true
            return true
        }
        guard ready else { return }
        let workspace = workspace, outputs = outputs
        Task {
            for _ in 0..<20 {
                if outputs.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) {
                    try? workspace.cleanup()
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            // Never delete data that Finder may still be moving. A later request reclaims
            // abandoned jobs using the verified per-job lock, after this process exits.
        }
    }
}
