import AppKit
import SwiftUI

/// Per-pane quick-access row (replaces a left sidebar), shown at the top of
/// each `PaneView` — navigates that specific pane, not "whichever pane is
/// active" (was previously a single row shared across both panes, which in
/// practice only ever visually sat above the left one).
struct FavoritesBarView: View {
    let onSelect: (URL) -> Void
    /// Refreshed on appear and on mount/unmount/rename — mounted disks can
    /// change at any time, unlike `commonLocations`, which never does.
    @State private var volumes: [MountedVolume] = []

    var body: some View {
        HStack(spacing: 16) {
            ForEach(FileSystemService.commonLocations, id: \.url) { location in
                locationButton(name: location.name, systemImage: icon(for: location.name), url: location.url)
            }
            if !volumes.isEmpty {
                Divider().frame(height: 16)
                ForEach(volumes) { volume in
                    locationButton(
                        name: volume.name,
                        systemImage: volume.isInternal ? "internaldrive" : "externaldrive",
                        url: volume.url
                    )
                    .contextMenu {
                        if volume.isEjectable {
                            Button("Unmount \"\(volume.name)\"") {
                                unmount(volume)
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
        .onAppear { refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didRenameVolumeNotification)) { _ in
            refreshVolumes()
        }
    }

    /// Labels never wrap — a narrow window truncates them with an ellipsis
    /// ("Downlo…") instead of breaking into multiple lines ("Dow nloa ds"),
    /// which both looked bad and made the bar's height jump around as the
    /// window resized. `.help` shows the full name on hover for anything
    /// truncated.
    private func locationButton(name: String, systemImage: String, url: URL) -> some View {
        Button {
            onSelect(url)
        } label: {
            Label(name, systemImage: systemImage)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private func refreshVolumes() {
        volumes = FileSystemService.mountedVolumes()
    }

    /// The `didUnmountNotification` observer above already refreshes
    /// `volumes` once the unmount actually completes — no need to update
    /// state directly here on success.
    private func unmount(_ volume: MountedVolume) {
        do {
            try FileSystemService.unmountVolume(at: volume.url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func icon(for name: String) -> String {
        switch name {
        case "Home": return "house"
        case "Desktop": return "menubar.dock.rectangle"
        case "Documents": return "doc.text"
        case "Downloads": return "arrow.down.circle"
        default: return "folder"
        }
    }
}
