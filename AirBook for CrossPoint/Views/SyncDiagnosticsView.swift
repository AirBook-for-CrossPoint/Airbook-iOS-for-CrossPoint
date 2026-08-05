import SwiftUI

// MARK: - Sync Diagnostics
//
// Hidden behind a long-press on the masthead title. Surfaces the negotiated
// protocol version, device-reported free heap, the recent BLE message log,
// and the last sync summary. Strictly read-only — meant for support, not
// configuration.

struct SyncDiagnosticsView: View {
    @Environment(SyncManager.self) private var sync
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.paperBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        phaseBlock
                        protocolBlock
                        summaryBlock
                        traceBlock
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Diagnostics")
                        .font(.system(.subheadline, design: .serif).weight(.bold))
                        .foregroundStyle(Color.paperInk)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(Color.paperInk)
                }
            }
            .toolbarBackground(Color.paperBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AirBook ↔ CrossPoint")
                .font(.system(.title3, design: .serif).weight(.bold))
                .foregroundStyle(Color.paperInk)
            Text("Last \(sync.traceLog.count) BLE messages on this connection")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.paperRule)
        }
    }

    private var phaseBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            label("CURRENT PHASE")
            Text(sync.phase.statusMessage)
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(Color.paperInk)
        }
    }

    private var protocolBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            label("PROTOCOL")
            switch sync.protocolVersion {
            case .v2:
                row(key: "Negotiated", value: "V2 (file ops only)")
            case .v3(let kb):
                row(key: "Negotiated", value: "V3")
                row(key: "Device free heap", value: "\(kb) KB")
            }
        }
    }

    @ViewBuilder
    private var summaryBlock: some View {
        if case .done(let summary) = sync.phase {
            VStack(alignment: .leading, spacing: 4) {
                label("LAST SYNC")
                row(key: "Files sent", value: "\(summary.uploaded)")
                row(key: "Duplicates skipped", value: "\(summary.duplicatesSkipped)")
                row(key: "Entries removed", value: "\(summary.entriesRemoved)")
                row(key: "Files freed", value: "\(summary.filesRemoved)")
                row(key: "Progress merged", value: "\(summary.progressMerged)")
                row(key: "Bookmarks merged", value: "\(summary.bookmarksMerged)")
                row(key: "Highlights merged", value: "\(summary.highlightsMerged)")
            }
        }
    }

    private var traceBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            label("BLE TRACE")
            if sync.traceLog.isEmpty {
                Text("Empty — no sync started yet on this app launch.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(sync.traceLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("→") ? Color.paperInk : Color.paperRule)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .foregroundStyle(Color.paperRule)
    }

    private func row(key: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.paperRule)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(Color.paperInk)
        }
    }
}
