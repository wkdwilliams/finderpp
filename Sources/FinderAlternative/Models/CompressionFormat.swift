import Foundation

/// RAR *creation* still isn't included — that would mean reimplementing
/// RARLAB's proprietary compression algorithm, which its own free-use
/// license explicitly prohibits (see `Services/FileSystemService.swift`'s
/// `CompressionError.rarCreationNotSupported`). RAR *extraction* is
/// different: RARLAB's own "unrar" source is free to use in any software
/// for that purpose, vendored via the `Unrar` package (`mtgto/Unrar.swift`)
/// — this project's first third-party dependency, justified because
/// there's no `unrar`/`unar` binary bundled with stock macOS the way
/// there's `unzip`/`tar`. See `CLAUDE.md` for the full reasoning.
enum CompressionFormat: String, CaseIterable, Identifiable, Sendable {
    case zip
    case tarGz
    case rar

    var id: String { rawValue }

    /// Formats this app can *create* — `CompressSheet`'s format picker
    /// iterates this, not `allCases`, so `.rar` (extraction-only) never
    /// appears as something to compress into.
    static let creatableCases: [CompressionFormat] = [.zip, .tarGz]

    var displayName: String {
        switch self {
        case .zip: return "Zip"
        case .tarGz: return "Tar.gz"
        case .rar: return "RAR"
        }
    }

    /// No leading dot — callers append it themselves (`"\(base).\(fileExtension)"`).
    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .tarGz: return "tar.gz"
        case .rar: return "rar"
        }
    }

    /// Recognizes archives this app can extract — both ones it created
    /// itself and ordinary zip/tar.gz/rar files from anywhere else. `.tgz`
    /// is accepted as the common alternate extension for `.tar.gz`, but
    /// `fileExtension`/`baseName(for:)` always use the canonical spelling.
    static func detect(from url: URL) -> CompressionFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGz }
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".rar") { return .rar }
        return nil
    }

    /// The archive's filename with this format's extension (and, for
    /// `.tarGz`, the `.tgz` alias) stripped — used to name the folder an
    /// archive gets extracted into.
    func baseName(for url: URL) -> String {
        let name = url.lastPathComponent
        switch self {
        case .zip:
            return String(name.dropLast(4)) // ".zip"
        case .tarGz:
            if name.lowercased().hasSuffix(".tar.gz") { return String(name.dropLast(7)) } // ".tar.gz"
            if name.lowercased().hasSuffix(".tgz") { return String(name.dropLast(4)) } // ".tgz"
            return name
        case .rar:
            return String(name.dropLast(4)) // ".rar"
        }
    }
}
