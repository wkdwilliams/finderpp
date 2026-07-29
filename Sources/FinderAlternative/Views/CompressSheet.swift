import SwiftUI

/// Presented from `FileContextMenu`'s "Compress…" action. The filename
/// field always shows the full name including its extension, kept in sync
/// with the format picker — switching formats rewrites just the extension,
/// never touching what the user typed as the base name.
struct CompressSheet: View {
    let items: [FileItem]
    let destinationDirectory: URL
    let onComplete: () -> Void

    @EnvironmentObject private var coordinator: FileOperationCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var baseName: String
    @State private var format: CompressionFormat = .zip

    init(items: [FileItem], destinationDirectory: URL, onComplete: @escaping () -> Void) {
        self.items = items
        self.destinationDirectory = destinationDirectory
        self.onComplete = onComplete
        let defaultName = items.count == 1
            ? items[0].url.deletingPathExtension().lastPathComponent
            : "Archive"
        _baseName = State(initialValue: defaultName)
    }

    private var trimmedBaseName: String {
        baseName.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Compress \(items.count) item\(items.count == 1 ? "" : "s")")
                .font(.headline)

            Picker("Format", selection: $format) {
                ForEach(CompressionFormat.creatableCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    TextField("Archive", text: $baseName)
                        .textFieldStyle(.roundedBorder)
                    Text(".\(format.fileExtension)")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Compress") { compress() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedBaseName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func compress() {
        let filename = "\(trimmedBaseName).\(format.fileExtension)"
        let destination = FileSystemService.uniqueDestinationURL(forFilename: filename, in: destinationDirectory)
        coordinator.compress(items.map(\.url), to: destination, format: format, then: onComplete)
        dismiss()
    }
}
