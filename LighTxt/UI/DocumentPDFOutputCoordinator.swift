import AppKit
import Darwin
import PDFKit
import UniformTypeIdentifiers

/// Owns the user-facing PDF and print workflow while the renderer remains a
/// synchronous, file-backed primitive. Both routes use the same immutable
/// document snapshot so unsaved edits are included and a long-running job
/// cannot mix revisions.
@MainActor
final class DocumentPDFOutputCoordinator {
    private static let outputQueue = DispatchQueue(
        label: "app.lightxt.document-pdf-output",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )

    var onStatusChange: ((_ text: String, _ busy: Bool, _ isError: Bool) -> Void)?
    var onBusyChange: ((_ isBusy: Bool) -> Void)?

    private(set) var isBusy = false
    private var operationID: UUID?
    private var cancellation: CancellationToken?
    private var savePanel: NSSavePanel?

    func exportPDF(
        snapshot: DocumentSnapshot,
        kind: DocumentPDFSourceKind,
        title: String,
        suggestedFileName: String,
        window: NSWindow?
    ) {
        guard let operation = beginOperation(status: "Choose where to save the PDF…") else {
            NSSound.beep()
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Markdown as PDF"
        panel.prompt = "Export"
        panel.nameFieldLabel = "Export As:"
        panel.nameFieldStringValue = suggestedFileName
        panel.allowedContentTypes = [.pdf]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        savePanel = panel

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard let self, self.operationID == operation.id else { return }
            self.savePanel = nil
            guard response == .OK, let destinationURL = panel?.url else {
                self.finishOperation(operation.id, status: "PDF export cancelled")
                return
            }
            self.startExport(
                snapshot: snapshot,
                kind: kind,
                title: title,
                destinationURL: destinationURL,
                operation: operation
            )
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    func print(
        snapshot: DocumentSnapshot,
        kind: DocumentPDFSourceKind,
        title: String,
        window _: NSWindow?
    ) {
        guard let operation = beginOperation(status: "Preparing to print…") else {
            NSSound.beep()
            return
        }
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        let printSettings = SendablePrintSettings(printInfo: printInfo)
        let pageSetup = DocumentPDFPageSetup.from(printInfo)
        onStatusChange?("Preparing to print…", true, false)

        Self.outputQueue.async { [weak self] in
            let result: Result<(DocumentPDFExportResult, TemporaryPDFOutput), Error>
            do {
                let temporary = try TemporaryPDFOutput()
                do {
                    let summary = try DocumentPDFExporter.export(
                        snapshot: snapshot,
                        kind: kind,
                        title: title,
                        to: temporary.fileURL,
                        pageSetup: pageSetup,
                        cancellation: operation.cancellation,
                        progress: self?.progressHandler(
                            operationID: operation.id,
                            action: "Preparing to print"
                        )
                    )
                    result = .success((summary, temporary))
                } catch {
                    temporary.remove()
                    throw error
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishPrintPreparation(
                    result,
                    operationID: operation.id,
                    printInfo: printSettings.printInfo
                )
            }
        }
    }

    func cancel() {
        savePanel?.cancel(nil)
        savePanel = nil
        cancellation?.cancel()
        cancellation = nil
        operationID = nil
        guard isBusy else { return }
        isBusy = false
        onBusyChange?(false)
    }

    private func startExport(
        snapshot: DocumentSnapshot,
        kind: DocumentPDFSourceKind,
        title: String,
        destinationURL: URL,
        operation: OperationIdentity
    ) {
        let expectedDestination: FileFingerprint?
        do {
            let accessStarted = destinationURL.startAccessingSecurityScopedResource()
            defer { if accessStarted { destinationURL.stopAccessingSecurityScopedResource() } }
            expectedDestination = try FileFingerprint.atPath(destinationURL.standardizedFileURL.path)
        } catch {
            finishOperation(operation.id, error: error)
            return
        }

        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        let pageSetup = DocumentPDFPageSetup.from(printInfo)
        onStatusChange?("Creating PDF…", true, false)

        Self.outputQueue.async { [weak self] in
            let accessStarted = destinationURL.startAccessingSecurityScopedResource()
            defer { if accessStarted { destinationURL.stopAccessingSecurityScopedResource() } }
            let result: Result<DocumentPDFExportResult, Error>
            do {
                let publication = try AtomicPDFPublication(
                    targetURL: destinationURL,
                    expectedDestination: expectedDestination
                )
                do {
                    let summary = try DocumentPDFExporter.export(
                        snapshot: snapshot,
                        kind: kind,
                        title: title,
                        to: publication.stagingURL,
                        pageSetup: pageSetup,
                        cancellation: operation.cancellation,
                        progress: self?.progressHandler(
                            operationID: operation.id,
                            action: "Creating PDF"
                        )
                    )
                    try publication.publish()
                    result = .success(summary)
                } catch {
                    publication.cancel()
                    throw error
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.operationID == operation.id else { return }
                switch result {
                case let .success(summary):
                    self.finishOperation(
                        operation.id,
                        status: "Exported \(Self.pageDescription(summary.pageCount))"
                    )
                case .failure(let error):
                    self.finishOperation(operation.id, error: error)
                }
            }
        }
    }

    private func finishPrintPreparation(
        _ result: Result<(DocumentPDFExportResult, TemporaryPDFOutput), Error>,
        operationID: UUID,
        printInfo: NSPrintInfo
    ) {
        guard self.operationID == operationID else {
            if case let .success((_, temporary)) = result { temporary.remove() }
            return
        }
        switch result {
        case let .failure(error):
            finishOperation(operationID, error: error)
        case let .success((summary, temporary)):
            defer { temporary.remove() }
            guard let document = PDFDocument(url: temporary.fileURL),
                  let printOperation = document.printOperation(
                    for: printInfo,
                    scalingMode: .pageScaleDownToFit,
                    autoRotate: true
                  ) else {
                finishOperation(operationID, error: DocumentPDFOutputError.couldNotOpenGeneratedPDF)
                return
            }
            onStatusChange?(
                "Ready to print \(Self.pageDescription(summary.pageCount))",
                false,
                false
            )
            printOperation.showsPrintPanel = true
            printOperation.showsProgressPanel = true
            let didPrint = printOperation.run()
            finishOperation(
                operationID,
                status: didPrint
                    ? "Sent \(Self.pageDescription(summary.pageCount)) to the printer"
                    : "Print cancelled"
            )
        }
    }

    private func beginOperation(status: String) -> OperationIdentity? {
        guard !isBusy else { return nil }
        let id = UUID()
        let cancellation = CancellationToken()
        operationID = id
        self.cancellation = cancellation
        isBusy = true
        onBusyChange?(true)
        onStatusChange?(status, false, false)
        return OperationIdentity(id: id, cancellation: cancellation)
    }

    private func finishOperation(_ id: UUID, status: String) {
        guard operationID == id else { return }
        operationID = nil
        cancellation = nil
        isBusy = false
        onBusyChange?(false)
        onStatusChange?(status, false, false)
    }

    private func finishOperation(_ id: UUID, error: Error) {
        if error is CancellationError {
            finishOperation(id, status: "PDF operation cancelled")
            return
        }
        guard operationID == id else { return }
        operationID = nil
        cancellation = nil
        isBusy = false
        onBusyChange?(false)
        onStatusChange?(error.localizedDescription, false, true)
    }

    private nonisolated func progressHandler(
        operationID: UUID,
        action: String
    ) -> @Sendable (DocumentPDFProgress) -> Void {
        { [weak self] update in
            let fraction = update.totalBytes > 0 ? update.fractionCompleted : 1
            let percent = min(100, max(0, Int(fraction * 100)))
            let pages = Self.pageDescription(update.pagesCompleted)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.operationID == operationID else { return }
                self.onStatusChange?("\(action) \(percent)%  ·  \(pages)", true, false)
            }
        }
    }

    private nonisolated static func pageDescription(_ count: Int) -> String {
        "\(count) \(count == 1 ? "page" : "pages")"
    }

    private struct OperationIdentity: @unchecked Sendable {
        let id: UUID
        let cancellation: CancellationToken
    }

    /// AppKit print settings are copied on the main actor, remain immutable
    /// while the PDF is prepared, and return to the main actor before use.
    private struct SendablePrintSettings: @unchecked Sendable {
        let printInfo: NSPrintInfo
    }
}

private enum DocumentPDFOutputError: Error, LocalizedError {
    case couldNotOpenGeneratedPDF

    var errorDescription: String? {
        switch self {
        case .couldNotOpenGeneratedPDF:
            "LighTxt created the PDF but could not open it for printing."
        }
    }
}

/// Keeps a print-only PDF private and removes it as soon as the print panel
/// finishes. The file never appears in recents or in the user's destination.
private nonisolated final class TemporaryPDFOutput: @unchecked Sendable {
    let directoryURL: URL
    let fileURL: URL
    private let lock = NSLock()
    private var wasRemoved = false

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt-print-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        directoryURL = directory
        fileURL = directory.appendingPathComponent("document.pdf")
    }

    deinit { remove() }

    func remove() {
        lock.lock()
        guard !wasRemoved else {
            lock.unlock()
            return
        }
        wasRemoved = true
        lock.unlock()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

/// Stages on the destination volume, synchronizes the completed PDF, and only
/// then atomically publishes it over the path authorized by the save panel.
private nonisolated final class AtomicPDFPublication: @unchecked Sendable {
    private let targetURL: URL
    private let expectedDestination: FileFingerprint?
    private let targetExisted: Bool
    private let targetMode: mode_t?
    private let stagingDirectoryURL: URL
    let stagingURL: URL
    private let lock = NSLock()
    private var isFinished = false

    init(targetURL: URL, expectedDestination: FileFingerprint?) throws {
        let target = targetURL.standardizedFileURL
        guard try FileFingerprint.atPath(target.path) == expectedDestination else {
            throw LighTxtCoreError.fileChangedExternally(path: target.path)
        }
        var status = stat()
        let targetExisted = lstat(target.path, &status) == 0
        let manager = FileManager.default
        let appropriateURL = targetExisted ? target : target.deletingLastPathComponent()
        let directory: URL
        if let replacement = try? manager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: appropriateURL,
            create: true
        ) {
            directory = replacement
        } else {
            directory = target.deletingLastPathComponent().appendingPathComponent(
                ".LighTxt-pdf-\(UUID().uuidString)",
                isDirectory: true
            )
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }

        self.targetURL = target
        self.expectedDestination = expectedDestination
        self.targetExisted = targetExisted
        targetMode = targetExisted ? mode_t(status.st_mode & 0o7777) : nil
        stagingDirectoryURL = directory
        stagingURL = directory.appendingPathComponent(UUID().uuidString + ".pdf")
    }

    deinit { cancel() }

    func publish() throws {
        lock.lock()
        let alreadyFinished = isFinished
        lock.unlock()
        guard !alreadyFinished else { return }

        let descriptor = Darwin.open(stagingURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw LighTxtCoreError.io(
                operation: "open completed PDF",
                path: stagingURL.path,
                code: errno
            )
        }
        if let targetMode, fchmod(descriptor, targetMode) != 0 {
            let code = errno
            Darwin.close(descriptor)
            throw LighTxtCoreError.io(
                operation: "preserve PDF permissions for",
                path: targetURL.path,
                code: code
            )
        }
        if fsync(descriptor) != 0 {
            let code = errno
            Darwin.close(descriptor)
            throw LighTxtCoreError.io(
                operation: "synchronize PDF export",
                path: stagingURL.path,
                code: code
            )
        }
        if Darwin.close(descriptor) != 0 {
            throw LighTxtCoreError.io(
                operation: "close PDF export",
                path: stagingURL.path,
                code: errno
            )
        }
        guard try FileFingerprint.atPath(targetURL.path) == expectedDestination else {
            throw LighTxtCoreError.fileChangedExternally(path: targetURL.path)
        }

        if targetExisted {
            _ = try FileManager.default.replaceItemAt(
                targetURL,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: targetURL)
        }
        lock.lock()
        isFinished = true
        lock.unlock()
        try? FileManager.default.removeItem(at: stagingDirectoryURL)
    }

    func cancel() {
        lock.lock()
        let shouldRemove = !isFinished
        isFinished = true
        lock.unlock()
        if shouldRemove { try? FileManager.default.removeItem(at: stagingDirectoryURL) }
    }
}
