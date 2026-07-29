import AppKit
import SwiftUI

/// Outgoing drag for `FileListView`, WITHOUT touching the click path.
///
/// History (the constraint this design exists to satisfy): SwiftUI
/// `.draggable` on Table rows was removed three times over — it intercepts
/// `mouseDown` to watch for a drag threshold and eats plain selection
/// clicks, and no delay/debounce tuning ever fully fixed it. A passive
/// `NSEvent` local monitor doesn't work here either: `NSTableView.mouseDown`
/// runs an AppKit mouse-tracking loop that pulls `leftMouseDragged` events
/// via `nextEvent(matching:)`, bypassing `sendEvent` — a monitor never sees
/// them, and starting a drag session mid-loop can wedge the table's click
/// tracking (the same bug through a different door).
///
/// This instead finds the `NSTableView` that SwiftUI's `Table` is backed by
/// (empirically confirmed — this app has observed "reentrant operation in
/// its NSTableView delegate" AppKit warnings from that very table) and
/// wraps its dataSource in a forwarding proxy that adds
/// `tableView(_:pasteboardWriterForRow:)`. AppKit then runs its own native
/// click-vs-drag disambiguation — the exact machinery Finder uses: the drag
/// threshold never eats clicks, pressing a selected row drags the whole
/// selection, deselection is deferred to mouse-up, drag images are native
/// row snapshots. Zero event-handling code on our side.
///
/// Fail-safe property: if SwiftUI's internals ever change such that the
/// backing table can't be found or the proxy gets permanently reset, the
/// worst case is "drag doesn't start" — clicks can never be affected,
/// because nothing here sees, gates, or consumes a single mouse event.
struct TableDragBridge: NSViewRepresentable {
    var urlForRow: @MainActor (Int) -> URL?
    var canDrag: @MainActor () -> Bool
    /// Called on plain (modifier-less) mouseDown over a row so the view can
    /// select it immediately. Enabling row-dragging switches NSTableView
    /// into deferred selection — highlight only on mouse-up — which reads
    /// as a small but noticeable click lag (confirmed by A/B screenshots
    /// with a held button: no highlight while pressed with drag on,
    /// instant highlight with drag off). A passive leftMouseDown monitor
    /// restores press-time highlight by eagerly writing the SwiftUI
    /// selection — a pure state write; the event itself is never consumed,
    /// so the click-safety invariant of this whole file still holds.
    var selectRow: @MainActor (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        // The backing table doesn't exist in the hierarchy until SwiftUI
        // finishes setting up — retry discovery a few times after launch;
        // afterwards every updateNSView re-checks (cheap once found).
        for delay in [0.0, 0.25, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak anchor, coordinator = context.coordinator] in
                guard let anchor else { return }
                coordinator.reassert(from: anchor)
            }
        }
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.proxy.urlForRow = urlForRow
        context.coordinator.proxy.canDrag = canDrag
        context.coordinator.selectRow = selectRow
        context.coordinator.canDrag = canDrag
        context.coordinator.reassert(from: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.uninstallPressMonitor() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        let proxy = DragDataSourceProxy()
        var selectRow: @MainActor (Int) -> Void = { _ in }
        var canDrag: @MainActor () -> Bool = { false }
        private weak var tableView: NSTableView?
        private var pressMonitor: Any?

        /// Restores press-time selection highlight (see `selectRow`'s doc
        /// comment). Observes only `leftMouseDown` and always returns the
        /// event unchanged — same never-consume invariant as
        /// `GridDragMonitor`.
        private func installPressMonitor() {
            guard pressMonitor == nil else { return }
            pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handlePress(event) }
                return event
            }
        }

        func uninstallPressMonitor() {
            if let pressMonitor { NSEvent.removeMonitor(pressMonitor) }
            pressMonitor = nil
        }

        private func handlePress(_ event: NSEvent) {
            guard let tableView, event.window === tableView.window,
                  canDrag(),
                  event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
            else { return }
            let point = tableView.convert(event.locationInWindow, from: nil)
            guard tableView.bounds.contains(point) else { return }
            let row = tableView.row(at: point)
            guard row >= 0 else { return }
            // Focus the table now too, or the eager selection renders in
            // the gray "unfocused window" style until mouse-up — AppKit
            // would transfer first responder on this click anyway.
            if tableView.window?.firstResponder !== tableView {
                tableView.window?.makeFirstResponder(tableView)
            }
            selectRow(row)
        }

        /// Installs (or re-installs, if SwiftUI replaced the dataSource
        /// during one of its own updates) the interposing proxy. Called on
        /// every SwiftUI update — a missed window just means drag is inert
        /// until the next update, never that clicks break.
        ///
        /// The actual mutation (swapping `dataSource`, which makes
        /// NSTableView re-query its data) is deferred to the next run-loop
        /// turn: `reassert` is typically called from `updateNSView`, i.e.
        /// *inside* SwiftUI's update transaction, and mutating the table
        /// there triggers the AppKit "reentrant operation in its
        /// NSTableView delegate" warning this project has already been
        /// bitten by once (see `FileOperationCoordinator
        /// .runCompletionHandler` for the first occurrence).
        func reassert(from anchor: NSView) {
            guard !dragDisabled else { return }
            if tableView == nil {
                tableView = Self.findTableView(near: anchor)
                if let tableView, dragDebug {
                    NSLog("FA_DRAG: discovered table %@ dataSource %@",
                          NSStringFromClass(type(of: tableView)),
                          tableView.dataSource.map { NSStringFromClass(type(of: $0)) } ?? "nil")
                    logDragMethodOverrides(of: tableView)
                }
            }
            guard let tableView else {
                if dragDebug { NSLog("FA_DRAG: no table found (window: %@)", anchor.window == nil ? "nil" : "set") }
                return
            }
            installPressMonitor()
            guard tableView.dataSource !== proxy else { return }
            guard let original = tableView.dataSource, !(original is DragDataSourceProxy) else { return }
            DispatchQueue.main.async { [proxy, weak tableView] in
                guard let tableView else { return }
                // Re-check: SwiftUI may have swapped the dataSource again
                // between the update pass and this deferred turn.
                guard tableView.dataSource !== proxy else { return }
                guard let original = tableView.dataSource, !(original is DragDataSourceProxy) else { return }
                proxy.original = original
                tableView.dataSource = proxy
                tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
                tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
                Self.allowRowDragging(on: tableView)
                if dragDebug { NSLog("FA_DRAG: proxy installed over %@", NSStringFromClass(type(of: original))) }
            }
        }

        /// SwiftUI's private table subclass overrides
        /// `canDragRows(with:at:)` (confirmed via FA_DRAG_DEBUG method
        /// introspection) and, with no SwiftUI-level drag modifiers
        /// registered, answers false — gating drag initiation before the
        /// dataSource is ever asked for a pasteboard writer, so the proxy
        /// alone does nothing. This registers (once) a runtime subclass of
        /// whatever class the instance actually is, overriding just that
        /// one method to answer true, and isa-swizzles the instance onto
        /// it. Per-instance, not class-global; if any step fails the
        /// instance is left untouched and drag is simply inert — the click
        /// path is native AppKit machinery either way and is never
        /// affected.
        private static func allowRowDragging(on tableView: NSTableView) {
            let baseClass: AnyClass = object_getClass(tableView)!
            let subclassName = "FADraggable_" + NSStringFromClass(baseClass)
            let subclass: AnyClass
            if let existing = NSClassFromString(subclassName) {
                if baseClass == existing { return } // already swizzled
                subclass = existing
            } else {
                let selector = NSSelectorFromString("canDragRowsWithIndexes:atPoint:")
                guard let created = objc_allocateClassPair(baseClass, subclassName, 0),
                      let baseMethod = class_getInstanceMethod(baseClass, selector) else { return }
                let block: @convention(block) (AnyObject, AnyObject, NSPoint) -> Bool = { _, _, _ in true }
                class_addMethod(created, selector, imp_implementationWithBlock(block), method_getTypeEncoding(baseMethod))
                objc_registerClassPair(created)
                subclass = created
            }
            object_setClass(tableView, subclass)
            if dragDebug { NSLog("FA_DRAG: instance swizzled to %@", subclassName) }
        }

        /// The anchor (a `.background` of the Table) sits behind the
        /// table's scroll view, so the right NSTableView is the one whose
        /// window-frame intersects the anchor's — that also disambiguates
        /// the two panes' tables.
        private static func findTableView(near anchor: NSView) -> NSTableView? {
            guard let window = anchor.window, let root = window.contentView else { return nil }
            let anchorFrame = anchor.convert(anchor.bounds, to: nil)
            var candidates: [NSTableView] = []
            var queue: [NSView] = [root]
            while let view = queue.popLast() {
                if let table = view as? NSTableView {
                    let tableFrame = table.convert(table.bounds, to: nil)
                    if tableFrame.intersects(anchorFrame) { candidates.append(table) }
                }
                queue.append(contentsOf: view.subviews)
            }
            return candidates.count == 1 ? candidates.first : nil
        }
    }
}

private let dragDebug = ProcessInfo.processInfo.environment["FA_DRAG_DEBUG"] == "1"
/// Kill switch for outgoing drag (both views) — dev/testing aid, e.g. for
/// A/B-ing whether a suspected interaction regression comes from the drag
/// machinery at all.
let dragDisabled = ProcessInfo.processInfo.environment["FA_NO_DRAG"] == "1"

/// FA_DRAG_DEBUG only: reports which drag-related NSTableView methods
/// SwiftUI's private subclass (or any class between it and NSTableView)
/// overrides — that determines whether the dataSource proxy can work at
/// all, or whether the subclass gates dragging before the dataSource is
/// ever consulted.
@MainActor
private func logDragMethodOverrides(of tableView: NSTableView) {
    let selectors: [Selector] = [
        NSSelectorFromString("canDragRowsWithIndexes:atPoint:"),
        NSSelectorFromString("mouseDown:"),
        NSSelectorFromString("dragImageForRowsWithIndexes:tableColumns:event:offset:"),
        NSSelectorFromString("verticalMotionCanBeginDrag")
    ]
    var cls: AnyClass? = type(of: tableView)
    while let current = cls, current != NSTableView.self {
        var count: UInt32 = 0
        if let methods = class_copyMethodList(current, &count) {
            for i in 0..<Int(count) {
                let sel = method_getName(methods[i])
                if selectors.contains(sel) {
                    NSLog("FA_DRAG: %@ overrides %@", NSStringFromClass(current), NSStringFromSelector(sel))
                }
            }
            free(methods)
        }
        cls = class_getSuperclass(current)
    }
}

/// Forwards everything to SwiftUI's own dataSource except
/// `tableView(_:pasteboardWriterForRow:)`, which it adds. `original` is held
/// strongly so it can't die between SwiftUI updates; when SwiftUI installs a
/// new dataSource of its own, `Coordinator.reassert` re-wraps that one and
/// this reference is released.
///
/// `nonisolated(unsafe)` because `forwardingTarget`/`responds` are
/// nonisolated `NSObject` overrides — AppKit only ever calls dataSource
/// methods on the main thread, and the drag closures hop through
/// `MainActor.assumeIsolated` before touching any SwiftUI state.
final class DragDataSourceProxy: NSObject, NSTableViewDataSource, NSOutlineViewDataSource {
    nonisolated(unsafe) var original: (any NSTableViewDataSource)?
    nonisolated(unsafe) var urlForRow: @MainActor (Int) -> URL? = { _ in nil }
    nonisolated(unsafe) var canDrag: @MainActor () -> Bool = { false }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    /// SwiftUI's `Table` is actually backed by an `NSOutlineView` subclass
    /// (`SwiftUIOutlineTableView`, confirmed via FA_DRAG_DEBUG logging), so
    /// drag initiation consults this outline-flavored method — the item is
    /// SwiftUI's opaque internal row object, mapped back to a flat row
    /// index via `row(forItem:)`. The plain `NSTableView` variant below is
    /// kept as a fallback in case a future macOS switches the backing view.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        writer(forRow: outlineView.row(forItem: item))
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        writer(forRow: row)
    }

    private func writer(forRow row: Int) -> (any NSPasteboardWriting)? {
        guard row >= 0 else { return nil }
        let canDrag = self.canDrag
        let urlForRow = self.urlForRow
        // `assumeIsolated` can't return the non-Sendable NSPasteboardWriting
        // directly — hand it out through an unsafe box instead. Safe because
        // the whole call runs synchronously on the main thread.
        nonisolated(unsafe) var writer: (any NSPasteboardWriting)?
        MainActor.assumeIsolated {
            if dragDebug { NSLog("FA_DRAG: pasteboardWriter for row %d", row) }
            guard canDrag() else { return }
            writer = urlForRow(row).map { $0 as NSURL }
        }
        return writer
    }
}
