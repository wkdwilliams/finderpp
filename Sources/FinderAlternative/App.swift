import AppKit
import SwiftUI

/// A plain SwiftPM executable (no .app bundle) doesn't get activated/
/// foregrounded by Launch Services the way a bundled app does — without
/// this, `swift run`'s window can end up behind Terminal with no Dock
/// icon, making it look like the app never launched.
///
/// Set `FA_HIDDEN_LAUNCH=1` to skip the foreground-activation step — used
/// for dev/test launches (verifying builds, screenshotting a specific
/// window by ID) so they don't steal focus from whatever else is on
/// screen. The window still exists and is screenshotable via its window
/// ID either way; this only affects whether the app jumps to the front.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI's WindowGroup opts into native macOS window tabbing by
        // default (View > Show Tab Bar, a "+" button in the title bar),
        // even though this app has no tab feature of its own — hide it.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        applyCustomAppIcon()
        guard ProcessInfo.processInfo.environment["FA_HIDDEN_LAUNCH"] != "1" else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Sets the Dock icon, About-panel icon, and app-switcher icon at
    /// runtime via `NSApplication.applicationIconImage` — this works even
    /// without a real `.app` bundle (no `Info.plist`/`CFBundleIconFile`,
    /// which is how a *bundled* app would normally declare its icon).
    /// `Bundle.module` is the SwiftPM-generated bundle holding this
    /// target's declared `resources` (see `Package.swift`), not the
    /// executable's own directory. No `subdirectory:` argument despite the
    /// source file living at `Resources/icon.png` — SwiftPM's `.copy` rule
    /// flattens it to the bundle's root (confirmed by inspecting the built
    /// `.bundle`), it doesn't preserve the source-relative subdirectory.
    ///
    /// **Only reached for the unbundled `swift run` dev workflow.** A real
    /// packaged release `.app` sets `CFBundleIconFile` in `Info.plist`
    /// instead and needs no runtime code at all — and *must* skip
    /// `Bundle.module` entirely: that accessor's own generated lookup
    /// requires a loose `<TargetName>.bundle` folder sitting at the `.app`
    /// root (sibling to `Contents`), and *anything* there breaks
    /// `codesign`'s resource-sealing (confirmed via `codesign --verify`:
    /// "code has no resources but signature indicates they must be
    /// present") — which is exactly what surfaces to a user as "'Finder++'
    /// is damaged and can't be opened" under Gatekeeper, not just an
    /// unsigned-developer warning. `Bundle.module` is also a crashing
    /// `fatalError` if unresolved, so this guard must run *before* ever
    /// touching it, not wrap it in a `do/catch`.
    @MainActor
    private func applyCustomAppIcon() {
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil else { return }
        guard let url = Bundle.module.url(forResource: "icon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }
}

/// Window scene identifier for the floating file-operation progress panel
/// — shared between `ContentView` (which opens/dismisses it) and the
/// `Window` scene declaration below.
let fileOperationProgressWindowID = "file-operation-progress"

@main
struct FinderAlternativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    // Owned here (not in ContentView) so both the main window and the
    // separate progress-panel Window scene below can reach it via
    // .environmentObject — environment doesn't propagate across scenes,
    // only down a single view tree.
    @StateObject private var operationCoordinator = FileOperationCoordinator()
    @StateObject private var appSettings = AppSettings()

    var body: some Scene {
        WindowGroup("Finder++") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(operationCoordinator)
                .environmentObject(appSettings)
        }
        .commands {
            CommandGroup(after: .help) {
                Button("Support Development…") {
                    appState.showingDonationSheet = true
                }
            }
            // `.sidebar` is the standard placement for panel-visibility
            // toggles in the View menu (macOS's own "Show/Hide Sidebar"
            // lives there) — shown by default, per explicit request.
            CommandGroup(after: .sidebar) {
                Button(appState.showsRightPane ? "Hide Right Pane" : "Show Right Pane") {
                    appState.showsRightPane.toggle()
                }
            }
        }

        Window("File Operation", id: fileOperationProgressWindowID) {
            OperationProgressWindow()
                .environmentObject(operationCoordinator)
        }
        .windowResizability(.contentSize)

        // The `Settings` scene is what actually adds "Settings…" (⌘,) to
        // the app menu shown in the screenshot — no manual Button/Command
        // needed, macOS wires this up itself.
        Settings {
            SettingsView()
                .environmentObject(appSettings)
        }
    }
}
