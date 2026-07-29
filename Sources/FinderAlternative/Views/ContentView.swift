import SwiftUI

private enum Pane {
    case left
    case right
}

struct ContentView: View {
    @StateObject private var leftViewModel = FileBrowserViewModel()
    @StateObject private var rightViewModel = FileBrowserViewModel(
        startingAt: FileManager.default.homeDirectoryForCurrentUser
    )
    @State private var activePane: Pane = .left
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var operationCoordinator: FileOperationCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HSplitView {
            PaneView(viewModel: leftViewModel, isActive: paneBinding(.left))
                .frame(minWidth: 320)
            if appState.showsRightPane {
                PaneView(viewModel: rightViewModel, isActive: paneBinding(.right))
                    .frame(minWidth: 320)
            }
        }
        .frame(minWidth: 900, minHeight: 550)
        // A file operation in progress shows a separate floating, blocking
        // progress panel (see OperationProgressWindow) — disabling and
        // dimming the main content here is what actually makes "the user
        // can't do anything else" true, since the panel being a different
        // window doesn't by itself prevent interacting with this one.
        .disabled(operationCoordinator.isBlocking)
        .overlay {
            if operationCoordinator.isBlocking {
                Color.black.opacity(0.15)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $appState.showingDonationSheet) {
            DonateView()
        }
        .onChange(of: operationCoordinator.isBlocking) { _, isBlocking in
            if isBlocking {
                openWindow(id: fileOperationProgressWindowID)
            } else {
                dismissWindow(id: fileOperationProgressWindowID)
            }
        }
        // Keyboard shortcuts/onKeyPress handlers route to "whichever pane
        // is active" — if the right pane is hidden while it was active,
        // fall back to the left one rather than routing to a pane that
        // isn't on screen.
        .onChange(of: appState.showsRightPane) { _, showsRightPane in
            if !showsRightPane { activePane = .left }
        }
    }

    private func paneBinding(_ pane: Pane) -> Binding<Bool> {
        Binding(
            get: { activePane == pane },
            set: { isActive in if isActive { activePane = pane } }
        )
    }
}
