import AppKit
import SwiftUI

/// Outgoing drag for `IconGridView`, WITHOUT touching the tap-gesture
/// stack. Unlike the Table (see `TableDragBridge`), the LazyVGrid has no
/// AppKit mouse-tracking loop — SwiftUI receives its events one at a time
/// through `sendEvent`, so a passive local event monitor sees everything.
///
/// The monitor's handler returns every event UNCHANGED on every code path.
/// That invariant is what makes the historical click-eating bug (three
/// failed `.draggable` attempts — it intercepts `mouseDown` to watch for a
/// drag threshold and ate plain selection clicks) impossible by
/// construction: nothing is consumed, gated, delayed, or re-routed, so the
/// existing `TapGesture` selection handling behaves exactly as if this
/// monitor didn't exist. Worst-case failure mode is "drag doesn't start",
/// never "click breaks".
///
/// Cell hit-rects come from `.onGeometryChange` recordings in the grid's
/// named coordinate space (`IconGridView` wires this up); the anchor view
/// below is flipped and exactly overlays the grid viewport, so event
/// locations convert into that same top-left space with no manual
/// title-bar/flip math.
@MainActor
final class CellFrameRegistry {
    var frames: [FileItem.ID: CGRect] = [:]
    func clear() { frames.removeAll() }
}

final class FlippedAnchorView: NSView {
    override var isFlipped: Bool { true }
}

struct GridDragMonitor: NSViewRepresentable {
    let registry: CellFrameRegistry
    var payloadURLs: @MainActor (FileItem.ID) -> [URL]
    var selectOnPress: @MainActor (FileItem.ID) -> Void
    var canDrag: @MainActor () -> Bool

    func makeNSView(context: Context) -> FlippedAnchorView {
        let anchor = FlippedAnchorView()
        context.coordinator.install(anchor: anchor)
        return anchor
    }

    func updateNSView(_ nsView: FlippedAnchorView, context: Context) {
        context.coordinator.registry = registry
        context.coordinator.payloadURLs = payloadURLs
        context.coordinator.selectOnPress = selectOnPress
        context.coordinator.canDrag = canDrag
    }

    static func dismantleNSView(_ nsView: FlippedAnchorView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.uninstall() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var registry: CellFrameRegistry?
        var payloadURLs: @MainActor (FileItem.ID) -> [URL] = { _ in [] }
        var selectOnPress: @MainActor (FileItem.ID) -> Void = { _ in }
        var canDrag: @MainActor () -> Bool = { false }

        private weak var anchor: FlippedAnchorView?
        private var monitor: Any?
        private var pending: (event: NSEvent, hitID: FileItem.ID, point: CGPoint)?

        func install(anchor: FlippedAnchorView) {
            guard !dragDisabled else { return }
            self.anchor = anchor
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                // INVARIANT: the incoming event is returned unchanged on
                // every path — see the type doc comment for why this must
                // never change.
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let anchor, event.window === anchor.window else {
                pending = nil
                return
            }
            switch event.type {
            case .leftMouseDown:
                pending = nil
                // ⌘/⌃/⇧-modified presses are selection edits (or context
                // clicks), never drag starts — matching the gesture split
                // in `IconGridView.singleClickGesture`.
                guard canDrag(),
                      event.modifierFlags.intersection([.command, .shift, .control]).isEmpty
                else { return }
                let point = anchor.convert(event.locationInWindow, from: nil)
                guard anchor.bounds.contains(point),
                      let hitID = registry?.frames.first(where: { $0.value.contains(point) })?.key
                else { return }
                // Select at press time, not on release: the TapGesture's
                // `.onEnded` only fires at mouse-up, which reads as click
                // lag. Pure state write — the event still flows through
                // untouched, and the mouse-up tap sets the same selection
                // again (a no-op).
                selectOnPress(hitID)
                pending = (event, hitID, point)
            case .leftMouseDragged:
                guard let pending else { return }
                let point = anchor.convert(event.locationInWindow, from: nil)
                let dx = point.x - pending.point.x
                let dy = point.y - pending.point.y
                // Same ~4pt threshold AppKit itself uses before treating a
                // press as a drag rather than a click.
                guard dx * dx + dy * dy > 16 else { return }
                self.pending = nil
                let urls = payloadURLs(pending.hitID)
                guard !urls.isEmpty else { return }
                beginFileDrag(urls: urls, event: pending.event, in: anchor)
            case .leftMouseUp:
                pending = nil
            default:
                break
            }
        }
    }
}
