import SwiftUI

/// Content of the standard macOS Settings window (`Settings…`, ⌘,) — see
/// the `Settings` scene in `App.swift`, which is what actually puts the
/// menu item in the app menu; nothing here does that wiring itself.
struct SettingsView: View {
    /// Shared with `FileListView`/`IconGridView` via `.environmentObject`,
    /// not `@AppStorage` — see `AppSettings`'s doc comment for why.
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("File Viewer Size")
                        Spacer()
                        Text("\(Int(settings.fileViewerScale * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.fileViewerScale, in: 0.75...1.5, step: 0.05)
                }
                Text("Scales row text and icon size in both list and icon view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
