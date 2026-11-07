import AppKit
import UniformTypeIdentifiers

final class ActionViewController: NSViewController {
    private enum Phase { case idle, working, failed, handingOff, cancelled }
    private let status = NSTextField(wrappingLabelWithString: "Preparing your images…")
    private let progress = NSProgressIndicator()
    private let errors = NSTextView()
    private let errorScroll = NSScrollView()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let doneButton = NSButton(title: "Close", target: nil, action: nil)
    private weak var contextSeen: NSExtensionContext?
    private var phase = Phase.idle
    private var originals: [NSItemProvider] = []
    private var workspace: ProcessingWorkspace?
    private var cancellation = ProcessingCancellation()
    private var task: Task<Void, Never>?
    private var outputs: [URL] = []
    private var delivery: ActionDelivery?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 530, height: 300))
        preferredContentSize = view.frame.size
        let title = NSTextField(labelWithString: "SnapFrame")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "Rounded corners, soft shadows, transparent PNG.\nYour original files are kept.")
        note.textColor = .secondaryLabelColor
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar
        errors.isEditable = false
        errors.font = .systemFont(ofSize: 12)
        errors.autoresizingMask = [.width]
        errorScroll.documentView = errors
        errorScroll.hasVerticalScroller = true
        errorScroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        errorScroll.isHidden = true
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        doneButton.target = self
        doneButton.action = #selector(returnToFinder)
        doneButton.keyEquivalent = "\r"
        doneButton.isHidden = true
        let buttons = NSStackView(views: [cancelButton, doneButton])
        let stack = NSStackView(views: [title, note, status, progress, errorScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorScroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let context = extensionContext, contextSeen !== context else { return }
        contextSeen = context
        originals = context.inputItems.compactMap { $0 as? NSExtensionItem }.flatMap { $0.attachments ?? [] }
        cancellation = ProcessingCancellation()
        outputs = []
        phase = .working
        errorScroll.isHidden = true
        doneButton.isHidden = true
        cancelButton.title = "Cancel"
        guard (1...16).contains(originals.count) else {
            showFailures([.init(name: "Selection", message: "Select between 1 and 16 PNG or JPEG images in Finder.")])
            return
        }
        do {
            _ = try ProcessingWorkspace.recoverAbandoned()
            workspace = try ProcessingWorkspace.create()
        } catch {
            showFailures([.init(name: "Couldn’t start", message: error.localizedDescription)])
            return
        }
        guard let workspace else { return }
        let providers = originals, cancellation = cancellation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var inputs: [BatchJobRunner.Input] = []
                var failures: [BatchJobRunner.Failure] = []
                var stagedBytes = 0
                for (index, provider) in providers.enumerated() {
                    try cancellation.check()
                    self.status.stringValue = "Reading image \(index + 1) of \(providers.count)…"
                    do {
                        let input = try await ActionInputAccess.stage(provider, index: index, workspace: workspace,
                            cancellation: cancellation, byteBudget: 256 * 1024 * 1024 - stagedBytes)
                        stagedBytes += (try? input.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        inputs.append(input)
                    } catch {
                        try cancellation.check()
                        failures.append(.init(name: provider.suggestedName ?? "Image \(index + 1)", message: error.localizedDescription))
                    }
                }
                if !inputs.isEmpty {
                    let worker = Task.detached(priority: .userInitiated) {
                        try BatchJobRunner.run(inputs, outputDirectory: workspace.outputs, cancellation: cancellation) { current, total in
                            Task { @MainActor in
                                guard self.phase == .working else { return }
                                self.status.stringValue = "Beautifying image \(current) of \(total)…"
                                self.progress.doubleValue = Double(current) / Double(total)
                            }
                        }
                    }
                    let result = try await worker.value
                    self.outputs = result.outputs
                    failures += result.failures
                }
                try cancellation.check()
                self.task = nil
                if failures.isEmpty { self.returnToFinder() }
                else { self.showFailures(failures) }
            } catch {
                self.task = nil
                guard !cancellation.isCancelled else { return }
                self.showFailures([.init(name: "Couldn’t finish", message: error.localizedDescription)])
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if phase == .working || phase == .failed { cancelWork(notifyContext: false) }
    }

    private func showFailures(_ failures: [BatchJobRunner.Failure]) {
        phase = .failed
        status.stringValue = "\(outputs.count) PNGs ready. \(failures.count) image(s) couldn’t be processed. Originals are kept."
        errors.string = failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n\n")
        errorScroll.isHidden = false
        doneButton.title = outputs.isEmpty ? "Close" : "Keep \(outputs.count) PNGs & Close"
        doneButton.isHidden = false
        cancelButton.title = outputs.isEmpty ? "Cancel" : "Discard Outputs"
    }

    @objc private func returnToFinder() {
        guard phase == .working || phase == .failed, let context = extensionContext else { return }
        // An empty host attachment list (for example an over-limit Finder selection)
        // must be cancelled, never completed as an empty replacement result.
        guard !originals.isEmpty else { cancelWork(notifyContext: true); return }
        let tracker = workspace.map { ActionDelivery(workspace: $0, outputs: outputs) }
        delivery = tracker
        let providers = outputs.enumerated().map { index, url in
            let provider = NSItemProvider()
            provider.suggestedName = url.lastPathComponent
            provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier,
                fileOptions: [.openInPlace], visibility: .all) { completion in
                completion(url, false, nil)
                tracker?.didVend(index)
                return nil
            }
            return provider
        }
        let item = NSExtensionItem()
        item.attachments = originals + providers
        guard originals.allSatisfy({ original in item.attachments?.contains { $0 === original } == true }) else {
            cancelWork(notifyContext: true)
            return
        }
        phase = .handingOff
        context.completeRequest(returningItems: [item]) { _ in tracker?.didComplete() }
    }

    @objc private func cancel() { cancelWork(notifyContext: true) }

    private func cancelWork(notifyContext: Bool) {
        guard phase != .handingOff, phase != .cancelled else { return }
        cancellation.cancel()
        task?.cancel()
        phase = .cancelled
        try? workspace?.cleanup()
        if notifyContext {
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
    }
}
