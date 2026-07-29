import Foundation

/// App-wide UI state that needs to be reachable from both `.commands`
/// (menu bar) and the main window's view hierarchy — e.g. triggering the
/// donation sheet from the Help menu.
@MainActor
final class AppState: ObservableObject {
    @Published var showingDonationSheet = false
    /// Driven by the View menu's "Hide/Show Right Pane" toggle — shown by
    /// default, per explicit request.
    @Published var showsRightPane = true
}
