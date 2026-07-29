import AppKit
import SwiftUI

/// Shown from the Help menu ("Support Development…"). Static list of crypto
/// donation addresses with copy-to-clipboard buttons.
struct DonateView: View {
    @Environment(\.dismiss) private var dismiss

    private let addresses: [(currency: String, address: String)] = [
        ("Monero (XMR)", "8AKyo4GbVYE8V7Sy7wb6fqiFpVVHdshPtT9QcMSnwrBE9EqbNfpTyTQcBGxj8tuagYcvJmNZASZU48Q553WiMaEq7KPcUTu"),
        ("Zcash (ZEC)", "t1g6QAif131irGn4ZNq59SAcpPHAftvjkzP"),
        ("Ethereum (ETH)", "0x890E83159915c60cCa44D2C6e8c2CA43736e2184")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Support This Project")
                .font(.title2)
                .bold()

            Text("If you find this app useful, donations are welcome.")
                .foregroundStyle(.secondary)

            Link(destination: URL(string: "https://buymeacoffee.com/lewy.w")!) {
                HStack {
                    Image(systemName: "cup.and.saucer.fill")
                    Text("Buy Me a Coffee")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(addresses, id: \.currency) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.currency)
                            .font(.subheadline)
                            .bold()
                        HStack {
                            Text(entry.address)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                copyToPasteboard(entry.address)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .help("Copy address")
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
