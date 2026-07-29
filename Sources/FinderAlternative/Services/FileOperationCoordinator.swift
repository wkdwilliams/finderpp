import Foundation

/// App-wide entry point for file operations, shared by both panes via
/// `.environmentObject`. Bridges `FileOperationQueue`'s actor-isolated
/// progress reporting back to the main actor through a `nonisolated`
/// method that hops itself, rather than scattering `Task { @MainActor in }`
/// at every call site inside the queue.
///
/// Tracks only the single front-of-queue operation (`current`), not a
/// history — the UI is a blocking modal progress window, not a log of past
/// operations, so nothing needs to look back further than "what's running
/// right now." If a second operation is enqueued while one is already
/// showing, its `.pending` report is dropped (see `apply`) rather than
/// hijacking the display; once the first operation clears, the queue's
/// own FIFO order means the second one's own `.running` report naturally
/// takes over `current` next — the window stays up across the transition,
/// which is exactly the "block until the whole queue drains" behavior
/// wanted here.
@MainActor
final class FileOperationCoordinator: ObservableObject {
    @Published private(set) var current: FileOperationStatus?

    private lazy var queue = FileOperationQueue { [weak self] status in
        self?.report(status)
    }
    private var completionHandlers: [UUID: () -> Void] = [:]

    var isBlocking: Bool { current != nil }

    nonisolated func report(_ status: FileOperationStatus) {
        Task { @MainActor in
            self.apply(status)
        }
    }

    private func apply(_ status: FileOperationStatus) {
        switch status.state {
        case .pending, .running:
            if current == nil || current?.id == status.id {
                current = status
            }
        case .done:
            if current?.id == status.id { current = nil }
            runCompletionHandler(for: status.id)
        case .cancelled, .failed:
            completionHandlers.removeValue(forKey: status.id)
            if current?.id == status.id { current = nil }
        }
    }

    /// Deferred to the next run-loop turn, not called inline — `current =
    /// nil` above synchronously flips `isBlocking`, which (via
    /// `ContentView`'s `.onChange`) closes the floating progress window and
    /// hands key-window/first-responder status back to the main window,
    /// all still within this same call frame. Running the completion
    /// handler (typically a view model's `reload()`, mutating a `Table`'s
    /// data source) synchronously alongside that produced a real, observed
    /// "Application performed a reentrant operation in its NSTableView
    /// delegate" AppKit warning — and a `Table` left in that state stops
    /// registering clicks afterward (arrow-key navigation keeps working)
    /// even though nothing about it looks wrong. Letting the window-
    /// dismissal cascade fully finish before the data mutation runs, on a
    /// separate turn, avoids the reentrancy.
    private func runCompletionHandler(for id: UUID) {
        guard let handler = completionHandlers.removeValue(forKey: id) else { return }
        DispatchQueue.main.async { handler() }
    }

    private func enqueue(_ kind: FileOperationKind, then onComplete: @escaping () -> Void) {
        let id = UUID()
        completionHandlers[id] = onComplete
        Task { await queue.enqueue(id: id, kind: kind) }
    }

    func cancel(id: UUID) {
        Task { await queue.cancel(id: id) }
    }

    func copy(_ urls: [URL], to destination: URL, then onComplete: @escaping () -> Void = {}) {
        enqueue(.copy(urls: urls, destination: destination), then: onComplete)
    }

    func move(_ urls: [URL], to destination: URL, then onComplete: @escaping () -> Void = {}) {
        enqueue(.move(urls: urls, destination: destination), then: onComplete)
    }

    func moveToTrash(_ urls: [URL], then onComplete: @escaping () -> Void = {}) {
        enqueue(.trash(urls: urls), then: onComplete)
    }

    func deletePermanently(_ urls: [URL], then onComplete: @escaping () -> Void = {}) {
        enqueue(.delete(urls: urls), then: onComplete)
    }

    func compress(_ urls: [URL], to destination: URL, format: CompressionFormat, then onComplete: @escaping () -> Void = {}) {
        enqueue(.compress(urls: urls, destination: destination, format: format), then: onComplete)
    }

    func extract(_ archive: URL, to destination: URL, format: CompressionFormat, then onComplete: @escaping () -> Void = {}) {
        enqueue(.extract(archive: archive, destination: destination, format: format), then: onComplete)
    }
}
