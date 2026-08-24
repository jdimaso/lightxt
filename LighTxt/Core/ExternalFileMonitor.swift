import Foundation
import Dispatch
import Darwin

/// Stable file-system identity for one path observation.
public nonisolated struct ExternalFileIdentity: Sendable, Equatable, Hashable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// A nanosecond-resolution modification timestamp from `stat(2)`.
public nonisolated struct ExternalFileModificationTime: Sendable, Equatable, Comparable {
    public let seconds: Int64
    public let nanoseconds: Int64

    public init(seconds: Int64, nanoseconds: Int64) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    public static func < (
        lhs: ExternalFileModificationTime,
        rhs: ExternalFileModificationTime
    ) -> Bool {
        (lhs.seconds, lhs.nanoseconds) < (rhs.seconds, rhs.nanoseconds)
    }
}

/// The small amount of metadata needed to classify a path change. Capturing a
/// state does not read file contents and therefore remains constant-time for
/// files of any size.
public nonisolated struct ExternalFileState: Sendable, Equatable {
    public let identity: ExternalFileIdentity
    public let byteCount: Int64
    public let modificationTime: ExternalFileModificationTime

    public init(
        identity: ExternalFileIdentity,
        byteCount: Int64,
        modificationTime: ExternalFileModificationTime
    ) {
        self.identity = identity
        self.byteCount = byteCount
        self.modificationTime = modificationTime
    }

    init(_ status: stat) {
        identity = ExternalFileIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
        byteCount = Int64(status.st_size)
        modificationTime = ExternalFileModificationTime(
            seconds: Int64(status.st_mtimespec.tv_sec),
            nanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }

    /// Returns nil when the path does not currently exist. Resolving the URL
    /// first intentionally follows a document symlink to the bytes LighTxt
    /// actually opened.
    public static func inspect(at url: URL) throws -> ExternalFileState? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        var status = stat()
        let result = lstat(path, &status)
        if result == 0 { return ExternalFileState(status) }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return nil }
        throw LighTxtCoreError.io(operation: "inspect", path: path, code: code)
    }
}

/// A metadata-based classification of an external path transition.
public nonisolated enum ExternalFileChangeKind: Sendable, Equatable {
    /// A missing path became available.
    case appeared
    /// The same inode grew. The range identifies newly addressable bytes.
    /// This is intentionally a metadata classification; it does not prove that
    /// an external writer left the earlier prefix untouched.
    case appended(range: Range<Int64>)
    /// The same inode became shorter.
    case truncated(fromByteCount: Int64, toByteCount: Int64)
    /// The same inode and length acquired a new modification timestamp.
    case modified
    /// The path now names a different device/inode.
    case replaced
    /// The path is no longer available.
    case removed
}

/// One coalesced external-file transition. UI integration can use
/// `documentWasClean` to choose automatic Reload versus conflict review, and
/// `followEOFRange` to extend a clean view that was already positioned at EOF.
public nonisolated struct ExternalFileChange: Sendable, Equatable {
    public let previous: ExternalFileState?
    public let current: ExternalFileState?
    public let kind: ExternalFileChangeKind
    public let documentWasClean: Bool

    public var isCleanChange: Bool { documentWasClean }

    public var followEOFRange: Range<Int64>? {
        guard case let .appended(range) = kind else { return nil }
        return range
    }

    public var canFollowEOFWithoutConflict: Bool {
        documentWasClean && followEOFRange != nil
    }

    /// Append can be consumed incrementally; every other transition requires a
    /// new document snapshot before the current contents can be trusted.
    public var requiresFullReload: Bool { followEOFRange == nil }

    public static func classify(
        previous: ExternalFileState?,
        current: ExternalFileState?,
        documentWasClean: Bool
    ) -> ExternalFileChange? {
        guard previous != current else { return nil }

        let kind: ExternalFileChangeKind
        switch (previous, current) {
        case (nil, .some):
            kind = .appeared
        case (.some, nil):
            kind = .removed
        case let (.some(old), .some(new)):
            if old.identity != new.identity {
                kind = .replaced
            } else if new.byteCount > old.byteCount {
                kind = .appended(range: old.byteCount..<new.byteCount)
            } else if new.byteCount < old.byteCount {
                kind = .truncated(
                    fromByteCount: old.byteCount,
                    toByteCount: new.byteCount
                )
            } else {
                kind = .modified
            }
        case (nil, nil):
            return nil
        }

        return ExternalFileChange(
            previous: previous,
            current: current,
            kind: kind,
            documentWasClean: documentWasClean
        )
    }
}

/// The disk observation represented by an external-change notification.
/// Available files are keyed by their exact identity, length, and nanosecond
/// modification time. This lets the UI remember a decision for one revision
/// without accidentally silencing a later write to the same path.
public nonisolated enum ExternalFileObservation: Sendable, Equatable {
    case available(ExternalFileState)
    case unavailable

    public init(change: ExternalFileChange) {
        if let current = change.current {
            self = .available(current)
        } else {
            self = .unavailable
        }
    }
}

/// Coalesces all external-change sources into one user decision per observed
/// disk revision. Both the path monitor and a failed file-backed read can see
/// the same change; callers use this tracker so those signals never create two
/// prompts. Declining applies only to that exact observation.
public nonisolated struct ExternalFileChangeDecisionTracker: Sendable {
    public enum Resolution: Sendable, Equatable {
        case awaitingDecision
        case declined
        case accepted
    }

    public private(set) var observation: ExternalFileObservation?
    public private(set) var resolution: Resolution?

    public init() {}

    /// Returns true exactly once for a new disk observation.
    @discardableResult
    public mutating func beginDecision(for change: ExternalFileChange) -> Bool {
        let candidate = ExternalFileObservation(change: change)
        guard observation != candidate else { return false }
        observation = candidate
        resolution = .awaitingDecision
        return true
    }

    public mutating func decline(_ change: ExternalFileChange) {
        observation = ExternalFileObservation(change: change)
        resolution = .declined
    }

    public mutating func accept(_ change: ExternalFileChange) {
        observation = ExternalFileObservation(change: change)
        resolution = .accepted
    }

    public mutating func reset() {
        observation = nil
        resolution = nil
    }
}

/// A lightweight per-document path monitor.
///
/// A vnode DispatchSource provides low-latency local notifications. A single
/// timer also samples metadata so replacement races, temporarily unavailable
/// paths, and file systems with incomplete vnode delivery still converge. Both
/// mechanisms feed one coalesced work item; event volume cannot create an
/// unbounded queue or retain file data.
public nonisolated final class ExternalFileMonitor: @unchecked Sendable {
    public enum ObservationMode: Sendable, Equatable {
        case automatic
        case pollingOnly
    }

    public struct Configuration: Sendable, Equatable {
        public let coalescingInterval: TimeInterval
        public let pollingInterval: TimeInterval
        public let observationMode: ObservationMode

        public init(
            coalescingInterval: TimeInterval = 0.15,
            pollingInterval: TimeInterval = 1.0,
            observationMode: ObservationMode = .automatic
        ) {
            let coalescing = coalescingInterval.isFinite
                ? max(0.01, coalescingInterval)
                : 0.15
            let polling = pollingInterval.isFinite
                ? max(0.05, pollingInterval)
                : 1.0
            self.coalescingInterval = coalescing
            self.pollingInterval = max(coalescing, polling)
            self.observationMode = observationMode
        }
    }

    public typealias ChangeHandler = @Sendable (ExternalFileChange) -> Void
    public typealias FailureHandler = @Sendable (LighTxtCoreError) -> Void

    public let url: URL

    private let configuration: Configuration
    private let deliveryQueue: DispatchQueue
    private let changeHandler: ChangeHandler
    private let failureHandler: FailureHandler?
    private let stateQueue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()

    private var lastObservedState: ExternalFileState?
    private var documentIsCleanStorage: Bool
    private var isStarted = false
    private var pendingSample: DispatchWorkItem?
    private var pollTimer: DispatchSourceTimer?
    private var fileSystemSource: DispatchSourceFileSystemObject?
    private var watchedIdentity: ExternalFileIdentity?
    private var fileSystemSourceNeedsRearm = false
    private var lastReportedFailure: LighTxtCoreError?

    public init(
        url: URL,
        configuration: Configuration = Configuration(),
        deliveryQueue: DispatchQueue = .main,
        documentIsClean: Bool = true,
        onFailure: FailureHandler? = nil,
        onChange: @escaping ChangeHandler
    ) throws {
        self.url = url.standardizedFileURL
        self.configuration = configuration
        self.deliveryQueue = deliveryQueue
        self.changeHandler = onChange
        self.failureHandler = onFailure
        self.stateQueue = DispatchQueue(
            label: "app.lightext.external-file-monitor.\(UUID().uuidString)",
            qos: .utility,
            autoreleaseFrequency: .workItem
        )
        self.lastObservedState = try ExternalFileState.inspect(at: self.url)
        self.documentIsCleanStorage = documentIsClean
        stateQueue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    public var baselineState: ExternalFileState? {
        withStateQueue { lastObservedState }
    }

    public var documentIsClean: Bool {
        withStateQueue { documentIsCleanStorage }
    }

    /// Starts observation. Repeated calls are harmless.
    public func start() {
        withStateQueue {
            guard !isStarted else { return }
            isStarted = true
            installPollingTimer()
            installFileSystemSource(for: lastObservedState)
            scheduleSample()
        }
    }

    /// Stops all observation and cancels any pending coalesced sample.
    public func stop() {
        withStateQueue {
            guard isStarted else { return }
            isStarted = false
            pendingSample?.cancel()
            pendingSample = nil
            pollTimer?.cancel()
            pollTimer = nil
            cancelFileSystemSource()
        }
    }

    /// Updates the edit state captured on the next emitted transition.
    public func setDocumentIsClean(_ isClean: Bool) {
        withStateQueue {
            documentIsCleanStorage = isClean
        }
    }

    /// Accepts the path's current state after Reload, Save, or Save As without
    /// emitting a self-change. The returned state can be retained by callers
    /// that need to coordinate their own reload transaction.
    @discardableResult
    public func acknowledgeCurrentFileState() throws -> ExternalFileState? {
        let state = try ExternalFileState.inspect(at: url)
        withStateQueue {
            pendingSample?.cancel()
            pendingSample = nil
            lastObservedState = state
            lastReportedFailure = nil
            if isStarted {
                installFileSystemSource(for: state)
            }
        }
        return state
    }

    /// Advances the monitor only when the pathname still represents the exact
    /// revision a reload actually opened. This closes the interval between
    /// pinning a lazy file-backed reader and acknowledging its path: if an
    /// atomic writer replaces the path in that interval, the newer revision is
    /// sampled and reported instead of being silently accepted.
    @discardableResult
    public func acknowledgeCurrentFileState(
        matching expectedState: ExternalFileState?
    ) throws -> Bool {
        let currentState = try ExternalFileState.inspect(at: url)
        guard currentState == expectedState else {
            withStateQueue { scheduleSample() }
            return false
        }
        withStateQueue {
            pendingSample?.cancel()
            pendingSample = nil
            lastObservedState = expectedState
            lastReportedFailure = nil
            if isStarted {
                installFileSystemSource(for: expectedState)
            }
        }
        return true
    }

    private func installPollingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        let leewayMilliseconds = max(
            1,
            min(250, Int(configuration.pollingInterval * 100))
        )
        timer.schedule(
            deadline: .now() + configuration.pollingInterval,
            repeating: configuration.pollingInterval,
            leeway: .milliseconds(leewayMilliseconds)
        )
        timer.setEventHandler { [weak self] in
            self?.scheduleSample()
        }
        pollTimer = timer
        timer.resume()
    }

    private func installFileSystemSource(for expectedState: ExternalFileState?) {
        cancelFileSystemSource()
        guard isStarted,
              configuration.observationMode == .automatic,
              let expectedState else { return }

        let descriptor = Darwin.open(url.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            // Polling remains active and will retry after the next state change.
            return
        }

        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0 else {
            Darwin.close(descriptor)
            return
        }
        let descriptorState = ExternalFileState(descriptorStatus)
        guard descriptorState.identity == expectedState.identity else {
            Darwin.close(descriptor)
            scheduleSample()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
            queue: stateQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let terminalEvents: DispatchSource.FileSystemEvent = [.rename, .delete, .revoke]
            if let events = self.fileSystemSource?.data,
               !events.intersection(terminalEvents).isEmpty {
                self.fileSystemSourceNeedsRearm = true
            }
            self.scheduleSample()
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        fileSystemSource = source
        watchedIdentity = descriptorState.identity
        fileSystemSourceNeedsRearm = false
        source.resume()

        if descriptorState != expectedState {
            scheduleSample()
        }
    }

    private func cancelFileSystemSource() {
        let source = fileSystemSource
        fileSystemSource = nil
        watchedIdentity = nil
        fileSystemSourceNeedsRearm = false
        source?.cancel()
    }

    /// Coalescing starts at the first notification rather than continually
    /// postponing on every write, so a hot append stream cannot starve delivery.
    private func scheduleSample() {
        guard isStarted, pendingSample == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSample = nil
            self.sampleCurrentState()
        }
        pendingSample = work
        stateQueue.asyncAfter(
            deadline: .now() + configuration.coalescingInterval,
            execute: work
        )
    }

    private func sampleCurrentState() {
        guard isStarted else { return }
        do {
            let current = try ExternalFileState.inspect(at: url)
            lastReportedFailure = nil
            let previous = lastObservedState
            lastObservedState = current

            if fileSystemSourceNeedsRearm || watchedIdentity != current?.identity {
                installFileSystemSource(for: current)
            }

            guard let change = ExternalFileChange.classify(
                previous: previous,
                current: current,
                documentWasClean: documentIsCleanStorage
            ) else { return }
            let handler = changeHandler
            deliveryQueue.async {
                handler(change)
            }
        } catch let error as LighTxtCoreError {
            reportFailureIfNeeded(error)
        } catch {
            reportFailureIfNeeded(.io(operation: "inspect", path: url.path, code: EIO))
        }
    }

    private func reportFailureIfNeeded(_ error: LighTxtCoreError) {
        guard error != lastReportedFailure else { return }
        lastReportedFailure = error
        guard let failureHandler else { return }
        deliveryQueue.async {
            failureHandler(error)
        }
    }

    private func withStateQueue<Result>(_ body: () throws -> Result) rethrows -> Result {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try stateQueue.sync(execute: body)
    }
}
