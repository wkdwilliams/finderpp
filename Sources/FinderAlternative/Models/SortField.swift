import Foundation

/// Which column `FileBrowserViewModel.filteredItems` is currently sorted
/// by — see `FileBrowserViewModel.toggleSort(_:)`.
enum SortField: Equatable {
    case name
    case size
    case modified
}
