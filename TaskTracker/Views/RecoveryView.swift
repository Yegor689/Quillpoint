import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Shown at the scene root when the store fails to open (a corrupt store or a failed
/// migration). The store is LEFT IN PLACE on failure — never moved or deleted — so:
///   • "Try Again" retries against the same data (fixes a transient failure, or works
///     after installing a build that fixes the migration), and
///   • "Start Fresh" is an explicit, confirmed choice that sets the old data aside
///     (recoverable) and starts empty.
/// This avoids the trap where retrying silently opened a blank store.
struct RecoveryView: View {
    let reason: String
    let onRetry: () -> Void
    let onStartFresh: () -> Void

    @State private var showDetails = false
    @State private var confirmStartFresh = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text("Quillpoint couldn't open your data")
                .font(.title2.bold())

            VStack(spacing: 6) {
                Text("Your data has not been lost.")
                    .fontWeight(.medium)
                Text("It's still on your Mac, untouched. This often happens after an update — installing the latest version of Quillpoint and choosing Try Again usually fixes it. If you're stuck, export diagnostics and reach out before starting fresh.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 440)

            HStack(spacing: 12) {
                Button("Try Again", action: onRetry)
                    .keyboardShortcut(.defaultAction)
                Button("Export Diagnostics…", action: exportDiagnostics)
            }

            // Destructive, de-emphasized, and confirmed — never a one-click blank start.
            Button("Start Fresh…", role: .destructive) { confirmStartFresh = true }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .confirmationDialog(
                    "Start with an empty Quillpoint?",
                    isPresented: $confirmStartFresh,
                    titleVisibility: .visible
                ) {
                    Button("Start Fresh", role: .destructive, action: onStartFresh)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your current data will be set aside in a Quarantine folder (not deleted) so it can be recovered later, and Quillpoint will open empty.")
                }

            DisclosureGroup("Technical details", isExpanded: $showDetails) {
                ScrollView {
                    Text(reason)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            .frame(maxWidth: 440)
        }
        .padding(40)
        .frame(minWidth: 540, minHeight: 460)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Quillpoint-diagnostics.txt"
        panel.title = "Export Diagnostics"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? DiagnosticLog.shared.exportText().write(to: url, atomically: true, encoding: .utf8)
    }
}
