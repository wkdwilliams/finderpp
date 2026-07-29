import SwiftUI

/// One half of the dual-pane browser: back/forward, breadcrumb, view-mode
/// toggle, name filter, and the file listing itself.
struct PaneView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @Binding var isActive: Bool
    @State private var viewMode: ViewMode = .list
    @State private var showsLocationBar: Bool = true
    @State private var locationBarText: String = ""
    /// See the `onChange(of: locationBarText)` guard that reads this.
    @State private var isProgrammaticLocationUpdate = false
    @State private var locationSuggestions: [String] = []
    /// Which suggestion arrow-key navigation currently has highlighted —
    /// `nil` until the user actually presses an arrow key, matching
    /// Windows Explorer's address bar (not pre-highlighting the first
    /// result the way some autocomplete UIs do).
    @State private var highlightedSuggestionIndex: Int?
    /// The location bar `TextField`'s own frame, in `paneCoordinateSpace`
    /// — used to position `locationSuggestionsDropdown` beneath it. Can't
    /// just `.overlay()` the dropdown directly on the text field: a plain
    /// `VStack` paints each child in declaration order, so an overlay
    /// attached to an *earlier* sibling (the text field) still renders
    /// underneath *later* siblings (the divider and file list below it) —
    /// `.zIndex()` only reorders within the same container, it doesn't let
    /// an earlier sibling's content paint over a later one. Tracking this
    /// frame and rendering the dropdown as its own top-level layer (see
    /// `body`) sidesteps that entirely.
    @State private var locationBarFrame: CGRect = .zero
    @FocusState private var isLocationBarFocused: Bool
    /// Real SwiftUI focus, kept in sync with `isActive` — `onKeyPress` and
    /// keyboard shortcuts scoped to "whichever pane is active" only fire
    /// when this pane actually holds focus, not just the hand-rolled
    /// `isActive` highlight.
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            paneContent
            if showsLocationBar, isLocationBarFocused, !locationSuggestions.isEmpty {
                locationSuggestionsDropdown
                    .offset(x: locationBarFrame.minX, y: locationBarFrame.maxY + 2)
            }
        }
        .coordinateSpace(name: "paneCoordinateSpace")
    }

    private var paneContent: some View {
        VStack(spacing: 0) {
            FavoritesBarView { url in
                viewModel.navigate(to: url)
            }
            Divider()

            HStack(spacing: 8) {
                Button(action: viewModel.goBack) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!viewModel.canGoBack)

                Button(action: viewModel.goForward) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!viewModel.canGoForward)

                BreadcrumbView(url: viewModel.currentDirectory) { viewModel.navigate(to: $0) }

                Spacer()

                Picker("View", selection: $viewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Image(systemName: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 80)
                .labelsHidden()

                Button {
                    showsLocationBar.toggle()
                } label: {
                    Image(systemName: "character.cursor.ibeam")
                }
                .help(showsLocationBar ? "Hide Location Bar" : "Show Location Bar")

                TextField("Filter by Name", text: $viewModel.filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            .padding(8)

            if showsLocationBar {
                TextField("Location", text: $locationBarText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isLocationBarFocused)
                    .onSubmit {
                        if let target = highlightedSuggestion {
                            selectSuggestion(target)
                        } else {
                            navigateToTypedLocation()
                        }
                    }
                    .onChange(of: locationBarText) { _, newValue in
                        // Guards against the programmatic update below
                        // (`onChange(of: viewModel.currentDirectory)`) —
                        // without this, navigating makes this fire too
                        // (it watches the same `locationBarText`), and
                        // since the new path's last component often
                        // matches itself as a completion of its own
                        // parent directory, a stray one-item dropdown
                        // reappeared right after every navigation.
                        guard !isProgrammaticLocationUpdate else {
                            isProgrammaticLocationUpdate = false
                            return
                        }
                        locationSuggestions = FileSystemService.directoryCompletions(for: newValue)
                        // A fresh suggestion set for newly-typed text has no
                        // relationship to whatever was highlighted before.
                        highlightedSuggestionIndex = nil
                    }
                    .onKeyPress(.tab) {
                        guard let target = highlightedSuggestion ?? locationSuggestions.first else { return .ignored }
                        locationBarText = target + "/"
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !locationSuggestions.isEmpty else { return .ignored }
                        let next = (highlightedSuggestionIndex ?? -1) + 1
                        highlightedSuggestionIndex = min(next, locationSuggestions.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !locationSuggestions.isEmpty else { return .ignored }
                        let previous = (highlightedSuggestionIndex ?? locationSuggestions.count) - 1
                        highlightedSuggestionIndex = max(previous, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard !locationSuggestions.isEmpty else { return .ignored }
                        locationSuggestions = []
                        highlightedSuggestionIndex = nil
                        return .handled
                    }
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("paneCoordinateSpace"))
                    } action: { newFrame in
                        locationBarFrame = newFrame
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }

            Divider()

            Group {
                switch viewMode {
                case .list:
                    FileListView(viewModel: viewModel)
                case .icon:
                    IconGridView(viewModel: viewModel)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            if focused { isActive = true }
        }
        .simultaneousGesture(TapGesture().onEnded {
            isActive = true
            isFocused = true
        })
        .onAppear {
            locationBarText = viewModel.currentDirectory.path
        }
        .onChange(of: viewModel.currentDirectory) { _, newValue in
            isProgrammaticLocationUpdate = true
            locationBarText = newValue.path
            locationSuggestions = []
            highlightedSuggestionIndex = nil
        }
    }

    /// `~`-expands and navigates the pane to whatever path the user typed;
    /// reverts to the current directory's path if it isn't a real directory
    /// rather than silently doing nothing.
    private func navigateToTypedLocation() {
        let expandedPath = (locationBarText as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            locationBarText = viewModel.currentDirectory.path
            return
        }
        viewModel.navigate(to: URL(fileURLWithPath: expandedPath))
    }

    private func selectSuggestion(_ suggestion: String) {
        locationSuggestions = []
        highlightedSuggestionIndex = nil
        locationBarText = suggestion
        viewModel.navigate(to: URL(fileURLWithPath: suggestion))
    }

    private var highlightedSuggestion: String? {
        guard let index = highlightedSuggestionIndex, locationSuggestions.indices.contains(index) else { return nil }
        return locationSuggestions[index]
    }

    /// A flat, square-cornered dropdown list directly under the location
    /// bar — deliberately not styled like a macOS popover (no rounded
    /// bubble, no arrow tail), closer to Windows Explorer's address-bar
    /// suggestion list. Arrow-key highlighting (`highlightedSuggestionIndex`)
    /// and mouse hover both drive the same highlight state, so keyboard and
    /// mouse users see consistent feedback.
    private var locationSuggestionsDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(locationSuggestions.enumerated()), id: \.offset) { index, suggestion in
                let isHighlighted = index == highlightedSuggestionIndex
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text((suggestion as NSString).lastPathComponent)
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(minWidth: 260, alignment: .leading)
                .background(isHighlighted ? Color.accentColor : Color.clear)
                .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                .contentShape(Rectangle())
                .onTapGesture { selectSuggestion(suggestion) }
                .onHover { isHovering in
                    if isHovering { highlightedSuggestionIndex = index }
                }
            }
        }
        .background(.background)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
        .shadow(radius: 3, y: 1)
    }
}
