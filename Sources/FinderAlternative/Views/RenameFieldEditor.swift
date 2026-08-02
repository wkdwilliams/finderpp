import AppKit

/// Finder-parity word selection for the inline rename field.
///
/// AppKit's own word granularity treats `report.final.txt` as ONE word —
/// a period between alphanumerics doesn't break a word (the same rule that
/// makes double-clicking a hostname select all of it). Confirmed here via
/// the accessibility API: double-clicking inside `aaaaaa` of `aaaaaa.txt`
/// reported `aaaaaa.txt` selected, so the next keystroke ate the extension.
/// Finder stops word selection at each period, which is what this restores.
/// (Spaces already break words correctly — `untitled folder` selected just
/// `untitled` — so a period is the only boundary that needs adding.)
///
/// The hook is `NSTextView.selectionRange(forProposedRange:granularity:)`,
/// and the object that has to implement it is the *window's shared field
/// editor*: a single `NSTextView` AppKit lends to whichever `NSTextField`
/// is being edited, including the one backing SwiftUI's `TextField`. There
/// is no API to hand a SwiftUI `TextField` a field editor of our own, so
/// the override is installed by isa-swizzling that shared instance onto a
/// runtime subclass — the same technique
/// `TableDragBridge.Coordinator.allowRowDragging` uses on SwiftUI's private
/// table class.
///
/// Since that editor is shared with every other text field in the window
/// (the location bar, the filter field), the subclass is inert unless
/// `isEditingFilename` is set — it forwards straight to super — so it can
/// be installed once and left in place rather than swapped in and out
/// around every rename, which would need an un-install on paths that are
/// easy to miss.
@MainActor
enum RenameFieldEditor {
    /// True only while an inline rename owns the field editor. `RenameState`
    /// maintains it; nothing else in the window gets filename semantics.
    static var isEditingFilename = false

    private static let subclassPrefix = "FARenameFieldEditor_"

    static func installFilenameWordSelection(on editor: NSTextView) {
        let baseClass: AnyClass = object_getClass(editor)!
        let baseName = NSStringFromClass(baseClass)
        guard !baseName.hasPrefix(subclassPrefix) else { return }
        let subclassName = subclassPrefix + baseName
        if let existing = NSClassFromString(subclassName) {
            object_setClass(editor, existing)
            return
        }
        // NSTextView's documented word-granularity hook,
        // `selectionRangeForProposedRange:granularity:`, is NOT usable here:
        // SwiftUI backs its `TextField` with a private field editor class
        // (`SwiftUI.._SystemTextFieldFieldEditor`) that never calls it —
        // verified by installing an override on it and logging, which
        // produced no calls at all on a double-click. Every selection
        // change does still funnel through `setSelectedRanges:affinity:
        // stillSelecting:`, NSTextView's designated selection setter, so
        // that is what gets narrowed instead.
        let selector = NSSelectorFromString("setSelectedRanges:affinity:stillSelecting:")
        guard let baseMethod = class_getInstanceMethod(baseClass, selector),
              let subclass = objc_allocateClassPair(baseClass, subclassName, 0)
        else { return }
        // Calling the base class's implementation directly IS the super
        // call — the subclass is what the instance is being moved onto.
        let superIMP = method_getImplementation(baseMethod)
        typealias SuperFn = @convention(c) (AnyObject, Selector, NSArray, UInt, ObjCBool) -> Void
        let block: @convention(block) (AnyObject, NSArray, UInt, ObjCBool) -> Void = { object, ranges, affinity, stillSelecting in
            nonisolated(unsafe) var narrowed: NSArray = ranges
            MainActor.assumeIsolated {
                narrowed = narrowedRanges(ranges, of: object) as NSArray
            }
            unsafeBitCast(superIMP, to: SuperFn.self)(object, selector, narrowed, affinity, stillSelecting)
        }
        class_addMethod(subclass, selector, imp_implementationWithBlock(block), method_getTypeEncoding(baseMethod))
        objc_registerClassPair(subclass)
        object_setClass(editor, subclass)
    }

    /// The selection AppKit is about to apply, narrowed to one dot-delimited
    /// run when — and only when — it's the word selection a double-click
    /// just produced. Everything else (caret moves, drag-selection, ⌘A,
    /// programmatic selection, any field that isn't a rename field) is
    /// returned untouched.
    ///
    /// A double-click is recognised from `NSApp.currentEvent` because the
    /// funnel this runs in isn't told the granularity.
    private static func narrowedRanges(_ ranges: NSArray, of object: AnyObject) -> [NSValue] {
        let original = (ranges as? [NSValue]) ?? []
        guard isEditingFilename,
              original.count == 1,
              let textView = object as? NSTextView,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .leftMouseUp,
              event.clickCount == 2
        else {
            pendingNarrowing = nil
            return original
        }
        let word = original[0].rangeValue
        switch event.type {
        case .leftMouseDown:
            let point = textView.convert(event.locationInWindow, from: nil)
            let click = textView.characterIndexForInsertion(at: point)
            let narrowed = filenameWordRange(in: textView.string as NSString, wordRange: word, clickedAt: click)
            pendingNarrowing = (word, narrowed)
            return [NSValue(range: narrowed)]
        default:
            // AppKit re-applies the whole word range on the *release* of a
            // double-click, which would undo the narrowing done on press.
            // Re-apply it — but only for the identical range, so a
            // double-click-and-drag (which extends the selection word by
            // word through `.leftMouseDragged`, clearing the memo above)
            // still selects everything the user dragged over.
            guard let memo = pendingNarrowing, NSEqualRanges(memo.original, word) else {
                pendingNarrowing = nil
                return original
            }
            pendingNarrowing = nil
            return [NSValue(range: memo.narrowed)]
        }
    }

    /// What the press half of a double-click narrowed, so the release half
    /// can repeat it. See `narrowedRanges`.
    private static var pendingNarrowing: (original: NSRange, narrowed: NSRange)?

    /// `wordRange` narrowed to the single dot-delimited run containing the
    /// click, so the extension is never swept up with the base name (nor the
    /// base name with the extension when the extension itself is clicked).
    ///
    /// `nonisolated` and taking everything by argument so it can be checked
    /// without a running app — `swift test` doesn't work on this machine
    /// (see CLAUDE.md), so this is verified by compiling it against a
    /// throwaway `main.swift` of assertions.
    nonisolated static func filenameWordRange(in text: NSString, wordRange: NSRange, clickedAt click: Int) -> NSRange {
        guard wordRange.length > 0, NSMaxRange(wordRange) <= text.length else { return wordRange }
        let anchor = min(max(click, wordRange.location), NSMaxRange(wordRange))
        var start = wordRange.location
        var end = NSMaxRange(wordRange)
        if anchor > start {
            let dot = text.range(of: ".", options: .backwards, range: NSRange(location: start, length: anchor - start))
            if dot.location != NSNotFound { start = NSMaxRange(dot) }
        }
        if anchor < end {
            let dot = text.range(of: ".", options: [], range: NSRange(location: anchor, length: end - anchor))
            if dot.location != NSNotFound { end = dot.location }
        }
        guard end <= start else { return NSRange(location: start, length: end - start) }
        // The click landed on a separator with nothing before it — a
        // dotfile's leading dot. Take the run that follows rather than
        // selecting nothing.
        let afterDot = min(anchor + 1, NSMaxRange(wordRange))
        var tailEnd = NSMaxRange(wordRange)
        if afterDot < tailEnd {
            let dot = text.range(of: ".", options: [], range: NSRange(location: afterDot, length: tailEnd - afterDot))
            if dot.location != NSNotFound { tailEnd = dot.location }
        }
        guard tailEnd > afterDot else { return wordRange }
        return NSRange(location: afterDot, length: tailEnd - afterDot)
    }
}
