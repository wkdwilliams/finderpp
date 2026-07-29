import Foundation

/// A mounted disk volume, for the favorites bar's dynamic "Locations"
/// section. `isInternal` picks between an internal- and external-drive
/// icon — see `FavoritesBarView`.
struct MountedVolume: Identifiable {
    var id: String { url.path }
    let name: String
    let url: URL
    let isInternal: Bool
    /// Whether "Unmount" should be offered for this volume — every mounted
    /// volume except the boot one, matching Finder's own eject-button
    /// criterion. Checked via `.volumeIsRootFileSystemKey` (the
    /// semantically-correct API for "is this the root filesystem"), not a
    /// string comparison against `/`, which a symlink could fool.
    /// Deliberately *not* gated on `.volumeIsRemovableKey`/
    /// `.volumeIsEjectableKey` — those describe the storage media, not the
    /// drive, and wrongly exclude ordinary external SSDs that report
    /// "Fixed" media. See `FileSystemService.mountedVolumes()`.
    let isEjectable: Bool
}
