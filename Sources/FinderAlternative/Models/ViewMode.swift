enum ViewMode: String, CaseIterable, Identifiable {
    case list
    case icon

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .icon: return "square.grid.2x2"
        }
    }
}
