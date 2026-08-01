import AppKit
import SwiftUI

/// Outgoing drag for `FileListView`, WITHOUT touching the click path.
///
/// History (the constraints this design exists to satisfy): SwiftUI
/// `.draggable` on Table rows was removed three times over — it intercepts
/// `mouseDown` to watch for a drag threshold and eats plain selection
/// clicks, and no delay/debounce tuning ever fully fixed it. A passive
/// `NSEvent` local monitor doesn't work here either: `NSTableView.mouseDown`
/// runs an AppKit mouse-tracking loop that pulls `leftMouseDragged` events
/// via `nextEvent(matching:)`, bypassing `sendEvent` — a monitor never sees
/// them, and starting a drag session mid-loop can wedge the table's click
/// tracking (the same bug through a different door).
///
/// A second constraint, learned the hard way: the first working version of
/// this bridge wrapped the backing table's `dataSource` in a forwarding
/// proxy that added `tableView(_:pasteboardWriterForRow:)` — and that
/// silently killed `.contextMenu(forSelectionType:)` (right-click showed no
/// menu at all, list view only). Empirically (FA_DRAG_DEBUG selector
/// logging), SwiftUI consults NO dataSource method during a right-click, so
/// a perfectly-forwarding proxy can't help: its menu path checks the
/// dataSource's *identity* — it must find SwiftUI's own
/// `AppKitOutlineTableCoordinator` there, and any foreign object (however
/// transparent) makes it bail. Confirmed by A/B with `FA_NO_DRAG`: proxy
/// installed → no menu; proxy skipped → menu fine.
///
/// So instead of replacing the dataSource, this adds the pasteboard-writer
/// methods directly onto SwiftUI's own coordinator *class*
/// (`class_addMethod`), keeping the dataSource object untouched. Per-table
/// routing (two panes = two tables sharing that class) goes through a
/// `TableDragConfig` associated object on each table view. AppKit then runs
/// its own native click-vs-drag disambiguation — the exact machinery Finder
/// uses: the drag threshold never eats clicks, pressing a selected row
/// drags the whole selection, deselection is deferred to mouse-up, drag
/// images are native row snapshots. Zero event-handling code on our side.
///
/// Fail-safe property: if SwiftUI's internals ever change such that the
/// backing table or its coordinator class can't be found, the worst case is
/// "drag doesn't start" — clicks and menus can never be affected, because
/// nothing here sees, gates, or consumes a single mouse event, and the
/// added methods return nil for any table without a config.
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
    /// Called on the same plain mouseDown, *before* `selectRow`, with the
    /// row and the event's click count — so the view can still see which
    /// rows were selected before this click (what Finder's
    /// click-a-selected-item-again rename trigger keys off).
    var pressedRow: @MainActor (Int, Int) -> Void

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
        context.coordinator.config.urlForRow = urlForRow
        context.coordinator.config.canDrag = canDrag
        context.coordinator.selectRow = selectRow
        context.coordinator.pressedRow = pressedRow
        context.coordinator.canDrag = canDrag
        context.coordinator.reassert(from: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.uninstallPressMonitor() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        let config = TableDragConfig()
        var selectRow: @MainActor (Int) -> Void = { _ in }
        var pressedRow: @MainActor (Int, Int) -> Void = { _, _ in }
        var canDrag: @MainActor () -> Bool = { false }
        private weak var tableView: NSTableView?
        private var pressMonitor: Any?
        private var activated = false

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
            pressedRow(row, event.clickCount)
            selectRow(row)
        }

        /// One-time (per table) activation: attach the routing config,
        /// extend the coordinator class, and refresh the table's cached
        /// "does my dataSource respond to drag methods?" flags.
        ///
        /// The actual mutation (re-setting `dataSource`, which makes
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
            guard !activated, tableView.dataSource != nil else { return }
            activated = true
            DispatchQueue.main.async { [config, weak tableView] in
                MainActor.assumeIsolated {
                    guard let tableView, let dataSource = tableView.dataSource else { return }
                    objc_setAssociatedObject(tableView, &tableDragConfigKey, config, .OBJC_ASSOCIATION_RETAIN)
                    TableDragConfig.installWriterMethods(onClassOf: dataSource)
                    // NSTableView caches its dataSource's respondsToSelector
                    // answers at assignment time — the drag methods were
                    // added to the class *after* SwiftUI set the dataSource,
                    // so force a re-cache or drag initiation never consults
                    // them. (A plain self-reassignment is short-circuited;
                    // the nil round-trip is not.)
                    tableView.dataSource = nil
                    tableView.dataSource = dataSource
                    tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
                    tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
                    Self.allowRowDragging(on: tableView)
                    if dragDebug { NSLog("FA_DRAG: activated drag on %@", NSStringFromClass(type(of: dataSource))) }
                }
            }
        }

        /// SwiftUI's private table subclass overrides
        /// `canDragRows(with:at:)` (confirmed via FA_DRAG_DEBUG method
        /// introspection) and, with no SwiftUI-level drag modifiers
        /// registered, answers false — gating drag initiation before the
        /// dataSource is ever asked for a pasteboard writer, so the added
        /// dataSource methods alone do nothing. This registers (once) a
        /// runtime subclass of whatever class the instance actually is,
        /// overriding just that one method to answer true, and
        /// isa-swizzles the instance onto it. Per-instance, not
        /// class-global; if any step fails the instance is left untouched
        /// and drag is simply inert — the click path is native AppKit
        /// machinery either way and is never affected.
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
/// machinery at all. This is how the dataSource-proxy/right-click breakage
/// described in the type doc comment was isolated.
let dragDisabled = ProcessInfo.processInfo.environment["FA_NO_DRAG"] == "1"

/// Associated-object key: each bridged `NSTableView` carries the
/// `TableDragConfig` the class-level writer methods route through.
private nonisolated(unsafe) var tableDragConfigKey: UInt8 = 0

/// FA_DRAG_DEBUG only: reports which drag-related NSTableView methods
/// SwiftUI's private subclass (or any class between it and NSTableView)
/// overrides — that determines whether adding dataSource drag methods can
/// work at all, or whether the subclass gates dragging before the
/// dataSource is ever consulted.
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

/// Per-table drag closures, attached to the backing table view as an
/// associated object. The pasteboard-writer methods this type installs on
/// SwiftUI's coordinator CLASS are shared by every table whose dataSource
/// is that class (both panes); routing per table goes through this object.
@MainActor
final class TableDragConfig: NSObject {
    var urlForRow: @MainActor (Int) -> URL? = { _ in nil }
    var canDrag: @MainActor () -> Bool = { false }

    fileprivate nonisolated static func writer(for tableView: NSTableView, row: Int) -> AnyObject? {
        // The ObjC-called blocks below are nonisolated; AppKit only ever
        // calls dataSource methods on the main thread, and
        // `assumeIsolated` can't return the non-Sendable writer directly —
        // hand it out through an unsafe box instead.
        nonisolated(unsafe) var result: AnyObject?
        MainActor.assumeIsolated {
            if dragDebug { NSLog("FA_DRAG: pasteboardWriter for row %d", row) }
            guard row >= 0,
                  let config = objc_getAssociatedObject(tableView, &tableDragConfigKey) as? TableDragConfig,
                  config.canDrag()
            else { return }
            result = config.urlForRow(row).map { $0 as NSURL }
        }
        return result
    }

    /// Installs `outlineView(_:pasteboardWriterForItem:)` (SwiftUI's
    /// `Table` is backed by an `NSOutlineView` subclass, confirmed via
    /// FA_DRAG_DEBUG logging, so drag initiation consults the
    /// outline-flavored method; the item is SwiftUI's opaque internal row
    /// object, mapped back to a flat row index via `row(forItem:)`) and the
    /// plain `tableView(_:pasteboardWriterForRow:)` variant (kept in case a
    /// future macOS switches the backing view) directly onto SwiftUI's own
    /// coordinator class — see the `TableDragBridge` doc comment for why
    /// the dataSource object itself must NOT be wrapped or replaced
    /// (identity-checked by the `.contextMenu` path).
    ///
    /// The coordinator class already implements the outline-flavored method
    /// natively (confirmed: `class_addMethod` returns false for it, true
    /// for the table-flavored one), presumably answering nil when no
    /// SwiftUI-level drag modifiers are registered — so plain
    /// `class_addMethod` alone leaves drag inert. When adding fails, the
    /// existing implementation is swapped via `method_setImplementation`:
    /// our writer is consulted first, and any table without a
    /// `TableDragConfig` (nil writer) falls through to SwiftUI's original
    /// implementation, preserving stock behavior everywhere else.
    @MainActor
    fileprivate static func installWriterMethods(onClassOf dataSource: AnyObject) {
        let cls: AnyClass = object_getClass(dataSource)!
        guard !installedClasses.contains(ObjectIdentifier(cls)) else { return }
        installedClasses.insert(ObjectIdentifier(cls))

        let outlineSel = NSSelectorFromString("outlineView:pasteboardWriterForItem:")
        typealias OutlineFn = @convention(c) (AnyObject, Selector, NSOutlineView, AnyObject) -> AnyObject?
        let outlineOriginal = IMPBox()
        let outlineBlock: @convention(block) (AnyObject, NSOutlineView, AnyObject) -> AnyObject? = { target, outlineView, item in
            nonisolated(unsafe) var row = -1
            MainActor.assumeIsolated { row = outlineView.row(forItem: item) }
            if let ours = writer(for: outlineView, row: row) { return ours }
            guard let imp = outlineOriginal.imp else { return nil }
            return unsafeBitCast(imp, to: OutlineFn.self)(target, outlineSel, outlineView, item)
        }
        install(outlineSel, imp_implementationWithBlock(outlineBlock), types: "@@:@@", on: cls, saving: outlineOriginal)

        let tableSel = NSSelectorFromString("tableView:pasteboardWriterForRow:")
        typealias TableFn = @convention(c) (AnyObject, Selector, NSTableView, Int) -> AnyObject?
        let tableOriginal = IMPBox()
        let tableBlock: @convention(block) (AnyObject, NSTableView, Int) -> AnyObject? = { target, tableView, row in
            if let ours = writer(for: tableView, row: row) { return ours }
            guard let imp = tableOriginal.imp else { return nil }
            return unsafeBitCast(imp, to: TableFn.self)(target, tableSel, tableView, row)
        }
        install(tableSel, imp_implementationWithBlock(tableBlock), types: "@@:@q", on: cls, saving: tableOriginal)
    }

    @MainActor
    private static func install(_ sel: Selector, _ imp: IMP, types: String, on cls: AnyClass, saving box: IMPBox) {
        if class_addMethod(cls, sel, imp, types) {
            if dragDebug { NSLog("FA_DRAG: added %@ on %@", NSStringFromSelector(sel), NSStringFromClass(cls)) }
        } else if let method = class_getInstanceMethod(cls, sel) {
            box.imp = method_setImplementation(method, imp)
            if dragDebug { NSLog("FA_DRAG: wrapped existing %@ on %@", NSStringFromSelector(sel), NSStringFromClass(cls)) }
        } else if dragDebug {
            NSLog("FA_DRAG: could not install %@ on %@", NSStringFromSelector(sel), NSStringFromClass(cls))
        }
    }

    /// Reference box for the pre-swap IMP: the replacement block must be
    /// built (to get its IMP) before `method_setImplementation` can return
    /// the original, so the block reads it through this indirection.
    private final class IMPBox {
        nonisolated(unsafe) var imp: IMP?
    }

    @MainActor private static var installedClasses = Set<ObjectIdentifier>()
}
