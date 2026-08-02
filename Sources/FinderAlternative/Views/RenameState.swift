import AppKit
import SwiftUI

/// Which row is currently being renamed, the in-progress name, and the
/// pending Finder-style "click a selected item again to rename it" trigger.
///
/// This is an `ObservableObject` rather than plain `@State` on
/// `FileListView` because SwiftUI's `Table` builds each `TableColumn`'s
/// cell view once per row value and then *caches* it: a `@State` change in
/// the view that owns the `Table` re-evaluates that view's `body`, but the
/// cell closures are never re-run for rows whose item is unchanged.
/// Confirmed empirically — logging inside the name-cell builder showed it
/// was not called at all after "Rename" was picked from the context menu,
/// so the rename `TextField` simply never appeared. Handing the cell its
/// own observable dependency makes the *cell* invalidate itself, which
/// doesn't depend on the table re-running the closure. `IconGridView` uses
/// the same type so both views share one set of rename semantics.
@MainActor
final class RenameState: ObservableObject {
    @Published var renamingID: FileItem.ID?
    @Published var draftName: String = ""
    /// Set when a rename fails, so it surfaces as an alert instead of the
    /// name silently snapping back to what it was.
    @Published var errorMessage: String?

    /// Applies the typed name to the row under edit. Installed by the row
    /// view that owns the field — it already closes over the right item, so
    /// this type never has to track which one that is.
    var onCommit: ((String) -> Void)?

    private var pending: DispatchWorkItem?
    /// Non-nil between `commit()` and the deferred handler running.
    private var committedName: String?

    var isRenaming: Bool { renamingID != nil }

    func begin(_ item: FileItem) {
        cancelPending()
        draftName = item.name
        renamingID = item.id
        RenameFieldEditor.isEditingFilename = true
    }

    /// Finder parity: every way of ending an inline rename EXCEPT Escape
    /// keeps the typed name — Return, clicking another file, clicking
    /// anywhere outside the field. Discarding on focus loss (what the field
    /// used to do) made "type a new name, then click the next file" throw
    /// the edit away silently, which is indistinguishable from rename being
    /// broken; that was the reported "can't rename a folder".
    ///
    /// Editing state is cleared synchronously so no other end-of-edit path
    /// can fire a second time for the same edit, but the handler itself is
    /// deferred one run-loop turn: it reloads the pane, i.e. mutates the
    /// `Table`'s data source, and the usual trigger is a click AppKit is
    /// still dispatching (first-responder handoff) — the same reentrancy
    /// that already produced an "Application performed a reentrant
    /// operation in its NSTableView delegate" warning once in this project
    /// (see `FileOperationCoordinator.runCompletionHandler`).
    func commit() {
        guard renamingID != nil else { return }
        committedName = draftName
        cancel()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let name = self.committedName else { return }
                self.committedName = nil
                self.onCommit?(name)
            }
        }
    }

    func cancel() {
        cancelPending()
        renamingID = nil
        RenameFieldEditor.isEditingFilename = false
    }

    /// Finder/Explorer parity: clicking an already-selected item a second
    /// time (slowly enough that it isn't a double-click) starts an inline
    /// rename. Call on every plain click; it cancels any previous pending
    /// trigger first, and only re-arms when `item` was the sole selection
    /// before the click.
    ///
    /// The wait is `NSEvent.doubleClickInterval` — the same system value
    /// (user-adjustable in Settings ▸ Accessibility ▸ Pointer Control) that
    /// decides whether two clicks are a double-click, so a rename can never
    /// fire out from under a double-click meant to open the item.
    func scheduleFromClick(on item: FileItem) {
        cancelPending()
        guard renamingID == nil else { return }
        let origin = NSEvent.mouseLocation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = nil
                // A press-and-hold or a drag that started from this click
                // must not turn into a rename when it ends.
                guard NSEvent.pressedMouseButtons == 0 else { return }
                let now = NSEvent.mouseLocation
                let dx = now.x - origin.x, dy = now.y - origin.y
                guard dx * dx + dy * dy <= 16 else { return }
                self.begin(item)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    /// Finder selects the base name (everything before the extension) as
    /// soon as a rename starts, so ⌘C copies the name, ⌘V replaces it, and
    /// typing overwrites it without eating the extension.
    ///
    /// This has to be done by hand because SwiftUI's `TextField` exposes no
    /// selection API at all, and without it the initial selection depends on
    /// how the field happened to gain focus: a context-menu rename came up
    /// with everything selected, but a click-triggered one came up with an
    /// empty selection at the caret — where ⌘C silently copies *nothing*
    /// (leaving whatever was on the pasteboard before) and ⌘V appends
    /// instead of replacing. That inconsistency is what made
    /// "copy a name, paste it onto another file" quietly do nothing.
    ///
    /// Reaches the field editor (an `NSTextView` shared by the window) one
    /// run-loop turn after focus is taken — it doesn't exist before that.
    static func failureMessage(from oldName: String, to newName: String, error: Error) -> String {
        // The overwhelmingly common cause, and `NSError`'s own wording for
        // it ("The file ... already exists") doesn't say which name clashed.
        if (error as NSError).code == NSFileWriteFileExistsError {
            return "“\(newName)” already exists in this folder."
        }
        return "Couldn’t rename “\(oldName)” to “\(newName)”. \(error.localizedDescription)"
    }

    static func selectBaseName(of name: String, retriesLeft: Int = 3) {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
                if retriesLeft > 0 { selectBaseName(of: name, retriesLeft: retriesLeft - 1) }
                return
            }
            // The only place the shared field editor is in hand — see
            // `RenameFieldEditor` for what this installs and why here.
            RenameFieldEditor.installFilenameWordSelection(on: editor)
            let full = name as NSString
            let base = full.deletingPathExtension
            // Dotfiles ("\.bashrc") have no base name to isolate — select
            // the whole thing rather than nothing.
            let length = base.isEmpty ? full.length : (base as NSString).length
            editor.setSelectedRange(NSRange(location: 0, length: length))
        }
    }
}
