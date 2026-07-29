import SwiftUI

/// Renders a path as a row of clickable segments (volume name down to the
/// current folder), letting the user jump to any ancestor directory.
struct BreadcrumbView: View {
    let url: URL
    let onNavigate: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        onNavigate(segment.url)
                    } label: {
                        HStack(spacing: 4) {
                            if index == 0 {
                                Image(systemName: "externaldrive")
                                    .font(.caption)
                            }
                            Text(segment.name)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == segments.count - 1 ? Color.primary : Color.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private var segments: [(name: String, url: URL)] {
        var result: [(name: String, url: URL)] = []
        var current = url.standardizedFileURL
        while true {
            if current.path == "/" {
                let volumeName = (try? current.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "Macintosh HD"
                result.append((volumeName, current))
                break
            }
            result.append((current.lastPathComponent, current))
            current = current.deletingLastPathComponent()
        }
        return result.reversed()
    }
}
