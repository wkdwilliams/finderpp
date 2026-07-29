import Foundation

/// Cross-scene UI settings, persisted to `UserDefaults` — owned by
/// `FinderAlternativeApp` and injected via `.environmentObject` into
/// whichever scenes need it, same sharing pattern as `AppState`/
/// `FileOperationCoordinator`.
///
/// Deliberately not `@AppStorage` read directly in `FileListView`/
/// `IconGridView`: that was tried first and only visibly updated those
/// views once the separate Settings window closed, not live while
/// dragging the slider — a real cross-scene propagation lag, not just a
/// perception issue. An explicit `@Published` property crossing scenes
/// through `.environmentObject` is Combine-driven, the same mechanism
/// already used for `operationCoordinator.isBlocking` (which *does* update
/// other windows immediately), and doesn't have that lag.
@MainActor
final class AppSettings: ObservableObject {
    private static let fileViewerScaleKey = "fileViewerScale"

    @Published var fileViewerScale: Double {
        didSet {
            UserDefaults.standard.set(fileViewerScale, forKey: Self.fileViewerScaleKey)
        }
    }

    init() {
        if let stored = UserDefaults.standard.object(forKey: Self.fileViewerScaleKey) as? Double {
            fileViewerScale = stored
        } else {
            fileViewerScale = 1.0
        }
    }
}
