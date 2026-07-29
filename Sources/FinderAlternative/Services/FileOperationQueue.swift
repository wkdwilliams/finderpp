import AppKit
import Foundation

enum FileOperationKind: Sendable {
    case copy(urls: [URL], destination: URL)
    case move(urls: [URL], destination: URL)
    case trash(urls: [URL])
    case delete(urls: [URL])
    case compress(urls: [URL], destination: URL, format: CompressionFormat)
    case extract(archive: URL, destination: URL, format: CompressionFormat)

    var label: String {
        func itemCount(_ urls: [URL]) -> String { "\(urls.count) item\(urls.count == 1 ? "" : "s")" }
        switch self {
        case .copy(let urls, let destination):
            return "Copying \(itemCount(urls)) to \(destination.lastPathComponent)"
        case .move(let urls, let destination):
            return "Moving \(itemCount(urls)) to \(destination.lastPathComponent)"
        case .trash(let urls):
            return "Moving \(itemCount(urls)) to Trash"
        case .delete(let urls):
            return "Deleting \(itemCount(urls)) permanently"
        case .compress(let urls, let destination, _):
            return "Compressing \(itemCount(urls)) into \(destination.lastPathComponent)"
        case .extract(let archive, _, _):
            return "Extracting \(archive.lastPathComponent)"
        }
    }

    /// Trash has no chunked, checkpointed implementation (`NSWorkspace
    /// .recycle` is one opaque async call) — nothing to meaningfully cancel
    /// once it's started. Compression/extraction are each a single opaque
    /// `Process` call for the same reason.
    var isCancellable: Bool {
        switch self {
        case .trash, .compress, .extract: return false
        default: return true
        }
    }
}

struct FileOperationStatus: Identifiable, Sendable {
    enum State: Sendable {
        case pending
        /// `bytesPerSecond` is nil for same-volume items (instant APFS
        /// clone/rename, nothing to measure), trash/delete (no byte-level
        /// tracking), and briefly at the very start of a cross-volume
        /// transfer before the first ~0.2s sampling window closes.
        case running(fractionCompleted: Double, bytesPerSecond: Int64?)
        case done
        case cancelled
        case failed(String)
    }

    let id: UUID
    let kind: FileOperationKind
    var state: State
}

struct FileOperationError: Error, Sendable {
    let message: String
}

/// A bare `actor` only serializes *between* suspension points — since
/// `perform(_:)` awaits (progress reporting, the trash continuation), a
/// second `enqueue` call could otherwise interleave with one already in
/// flight. An explicit backing array + single driving loop guarantees true
/// FIFO queueing instead of relying on actor call-serialization.
actor FileOperationQueue {
    private var pending: [FileOperation] = []
    private var isRunning = false
    private let onStatusChange: @Sendable (FileOperationStatus) -> Void
    /// Only holds an entry while an operation is actually running (not
    /// while merely queued) — that's the only state `cancel(id:)` needs to
    /// reach into mid-flight.
    private var activeProgress: [UUID: Progress] = [:]

    struct FileOperation: Sendable {
        let id: UUID
        let kind: FileOperationKind
    }

    init(onStatusChange: @escaping @Sendable (FileOperationStatus) -> Void) {
        self.onStatusChange = onStatusChange
    }

    func enqueue(id: UUID, kind: FileOperationKind) {
        pending.append(FileOperation(id: id, kind: kind))
        onStatusChange(FileOperationStatus(id: id, kind: kind, state: .pending))
        startLoopIfNeeded()
    }

    /// Cancels a still-queued operation outright (never started), or asks a
    /// running one's `Progress` to stop — the running operation's own loop
    /// notices `isCancelled` and unwinds (see `copyFileWithProgress`/
    /// `copyRecursivelyWithProgress` in `FileSystemService`).
    func cancel(id: UUID) {
        if let progress = activeProgress[id] {
            progress.cancel()
            return
        }
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let op = pending.remove(at: index)
        onStatusChange(FileOperationStatus(id: op.id, kind: op.kind, state: .cancelled))
    }

    private func startLoopIfNeeded() {
        guard !isRunning else { return }
        isRunning = true
        Task { await runLoop() }
    }

    private func runLoop() async {
        while !pending.isEmpty {
            let op = pending.removeFirst()
            do {
                try await perform(id: op.id, kind: op.kind)
                onStatusChange(FileOperationStatus(id: op.id, kind: op.kind, state: .done))
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
                    onStatusChange(FileOperationStatus(id: op.id, kind: op.kind, state: .cancelled))
                } else {
                    let message = (error as? FileOperationError)?.message ?? error.localizedDescription
                    onStatusChange(FileOperationStatus(id: op.id, kind: op.kind, state: .failed(message)))
                }
            }
            activeProgress[op.id] = nil
        }
        isRunning = false
    }

    private func perform(id: UUID, kind: FileOperationKind) async throws {
        switch kind {
        case .copy(let urls, let destination):
            try performBatch(id: id, kind: kind, urls: urls) { url, progress in
                try FileSystemService.copyItemWithProgress(at: url, toDirectory: destination, progress: progress)
            }
        case .move(let urls, let destination):
            try performBatch(id: id, kind: kind, urls: urls) { url, progress in
                try FileSystemService.moveItemWithProgress(at: url, toDirectory: destination, progress: progress)
            }
        case .trash(let urls):
            onStatusChange(FileOperationStatus(id: id, kind: kind, state: .running(fractionCompleted: 0, bytesPerSecond: nil)))
            try await Self.trash(urls)
        case .delete(let urls):
            try performBatch(id: id, kind: kind, urls: urls) { url, progress in
                try FileManager.default.removeItem(at: url)
                progress.completedUnitCount += 1
                return url
            }
        case .compress(let urls, let destination, let format):
            onStatusChange(FileOperationStatus(id: id, kind: kind, state: .running(fractionCompleted: 0, bytesPerSecond: nil)))
            try await Self.compress(urls, to: destination, format: format)
        case .extract(let archive, let destination, let format):
            onStatusChange(FileOperationStatus(id: id, kind: kind, state: .running(fractionCompleted: 0, bytesPerSecond: nil)))
            try await Self.extract(archive, to: destination, format: format)
        }
    }

    /// Runs `operation` once per URL against one shared `Progress` (so
    /// per-item contributions accumulate into an overall batch fraction —
    /// see `FileSystemService.copyItemWithProgress`'s doc comment for why
    /// each item adds its own share rather than jumping straight to the
    /// total), publishing `fractionCompleted` via KVO as it changes.
    private func performBatch(
        id: UUID,
        kind: FileOperationKind,
        urls: [URL],
        _ operation: @escaping (URL, Progress) throws -> URL
    ) throws {
        let totalUnits: Int64
        if case .delete = kind {
            totalUnits = Int64(urls.count) // no bytes to speak of for a removeItem
        } else {
            totalUnits = max(urls.reduce(Int64(0)) { $0 + FileSystemService.totalSize(of: $1) }, 1)
        }
        let progress = Progress(totalUnitCount: totalUnits)
        activeProgress[id] = progress

        let onStatusChange = self.onStatusChange
        // Explicit report before the loop starts (not just relying on the
        // KVO observer below) — KVO only fires on an actual value change,
        // so a batch whose first item finishes near-instantly could
        // otherwise jump straight from .pending to .done with no visible
        // .running transition in between.
        onStatusChange(FileOperationStatus(id: id, kind: kind, state: .running(fractionCompleted: 0, bytesPerSecond: nil)))
        // Throughput is set by FileSystemService's chunked copy loop (only
        // meaningful cross-volume — see its doc comment); reading it here
        // whenever fractionCompleted changes is simpler than a second KVO
        // observer and updates on the same cadence either way.
        let observation = progress.observe(\.fractionCompleted, options: [.new]) { prog, _ in
            let throughput = prog.throughput.map(Int64.init)
            onStatusChange(FileOperationStatus(id: id, kind: kind, state: .running(fractionCompleted: prog.fractionCompleted, bytesPerSecond: throughput)))
        }
        defer { observation.invalidate() }

        for url in urls {
            if progress.isCancelled {
                throw CocoaError(.userCancelled)
            }
            _ = try operation(url, progress)
        }
    }

    /// `NSWorkspace.recycle` is batch (one Trash animation for the whole
    /// selection) and async, unlike `FileManager.trashItem`'s one-file-at-a-
    /// time synchronous call — matches Finder's own ⌘⌫ behavior.
    private static func trash(_ urls: [URL]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task { @MainActor in
                NSWorkspace.shared.recycle(urls) { _, error in
                    if let error {
                        continuation.resume(throwing: FileOperationError(message: error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// `zip`/`tar` (via `Process.run()`/`.waitUntilExit()`) block the
    /// calling thread for the whole archive — running that directly inside
    /// the actor's async method would tie up its cooperative-pool thread,
    /// so it's dispatched to a background queue instead, same shape as
    /// `trash` above.
    private static func compress(_ urls: [URL], to destination: URL, format: CompressionFormat) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try FileSystemService.compress(urls, to: destination, format: format)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: FileOperationError(message: error.localizedDescription))
                }
            }
        }
    }

    /// Same reasoning as `compress` above — `unzip`/`tar` block the calling
    /// thread, so this runs off the actor's own cooperative-pool thread.
    private static func extract(_ archive: URL, to destination: URL, format: CompressionFormat) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try FileSystemService.extract(archive, to: destination, format: format)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: FileOperationError(message: error.localizedDescription))
                }
            }
        }
    }
}
