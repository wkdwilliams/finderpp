import AppKit
import SwiftUI

/// Content of the floating, always-on-top file-operation progress panel
/// (see the `Window` scene in `App.swift`). `ContentView` opens this window
/// and disables its own content whenever `FileOperationCoordinator
/// .isBlocking` is true, and dismisses it once the queue drains — this view
/// just renders whatever `coordinator.current` says right now.
struct OperationProgressWindow: View {
    @EnvironmentObject private var coordinator: FileOperationCoordinator

    var body: some View {
        VStack(spacing: 16) {
            if let current = coordinator.current {
                Text(current.kind.label)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                progressView(for: current)

                if current.kind.isCancellable {
                    Button("Cancel") {
                        coordinator.cancel(id: current.id)
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    Text("This operation can't be cancelled once started.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Briefly visible between the window opening and the first
                // status update landing, or while the queue transitions
                // from one operation to the next.
                ProgressView()
                Text("Preparing…")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(FloatingPanelConfigurator(isBlocking: { coordinator.isBlocking }))
    }

    @ViewBuilder
    private func progressView(for status: FileOperationStatus) -> some View {
        switch status.state {
        case .running(let fraction, let bytesPerSecond) where fraction > 0:
            ProgressView(value: fraction)
            HStack {
                Text("\(Int(fraction * 100))%")
                if let bytesPerSecond {
                    Spacer()
                    Text("\(Self.speedFormatter.string(fromByteCount: bytesPerSecond))/s")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .pending, .running:
            ProgressView() // indeterminate — nothing measurable reported yet
            Text("Starting…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .done, .cancelled, .failed:
            ProgressView(value: 1.0)
        }
    }

    private static let speedFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

/// Makes the hosting `NSWindow` a floating panel: always on top of the
/// app's other windows (`.floating` level), draggable by its background,
/// with its close button hidden (not removed from the style mask — SwiftUI's
/// `dismissWindow(id:)` needs `.closable` present to actually work; a
/// window with only `[.titled]` in its mask silently fails to dismiss) and
/// blocked from closing via ⌘W/the Window menu while an operation is still
/// active, via `windowShouldClose`.
private struct FloatingPanelConfigurator: NSViewRepresentable {
    let isBlocking: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask = [.titled, .closable]
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.level = .floating
            window.isMovableByWindowBackground = true
            window.title = "File Operation"
            window.hidesOnDeactivate = false
            window.delegate = context.coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> CloseGuard {
        CloseGuard(isBlocking: isBlocking)
    }

    /// Retained by SwiftUI for the represented view's lifetime — `NSWindow
    /// .delegate` is `weak`, so this can't just be a local/temporary value.
    final class CloseGuard: NSObject, NSWindowDelegate {
        let isBlocking: () -> Bool
        init(isBlocking: @escaping () -> Bool) { self.isBlocking = isBlocking }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            !isBlocking()
        }
    }
}
