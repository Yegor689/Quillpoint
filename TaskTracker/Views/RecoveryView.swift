import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Shown at the scene root when the store fails to open (a corrupt store or a
/// failed migration). The store is never deleted on failure — it's quarantined —
/// so this screen's job is to reassure the user their data is preserved and offer
/// safe next steps: retry, reveal the quarantined copy, or export diagnostics for a
/// bug report. Restoring a backup happens through the normal Backups UI once the app
/// comes up on a healthy store, so it isn't offered here (there is no live store to
/// restore into while bring-up is failing).
struct RecoveryView: View {
    let reason: String
    let quarantineURL: URL?
    let onRetry: () -> Void

    @State private var showDetails = false

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
                if quarantineURL != nil {
                    Text("A copy has been set aside so it can be recovered. Try again — if it keeps failing, export diagnostics and reach out, or restore a backup from the Backups menu once the app opens.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Try again — if it keeps failing, export diagnostics and reach out, or restore a backup from the Backups menu once the app opens.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button("Try Again", action: onRetry)
                    .keyboardShortcut(.defaultAction)
                if let quarantineURL {
                    Button("Reveal Preserved Data") {
                        NSWorkspace.shared.activateFileViewerSelecting([quarantineURL])
                    }
                }
                Button("Export Diagnostics…", action: exportDiagnostics)
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
            .frame(maxWidth: 420)
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 420)
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
