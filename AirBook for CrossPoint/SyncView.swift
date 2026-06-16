import SwiftUI

// MARK: - Sync View

struct SyncView: View {
    @Environment(BookStore.self) private var store
    @Environment(SyncManager.self) private var sync
    @Environment(ReadingStateStore.self) private var readingStateStore
    @Environment(FirmwareUpdateManager.self) private var firmwareUpdater
    @Environment(FirmwareReleaseChecker.self) private var releaseChecker
    @Environment(\.dismiss) private var dismiss

    @State private var showingFirmwareUpdate = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.paperBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    SyncStatusHeader(phase: sync.phase)
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                        .padding(.bottom, 16)
                        .animation(.easeInOut(duration: 0.3), value: sync.phase)

                    Rectangle()
                        .fill(Color.paperInk.opacity(0.12))
                        .frame(height: 0.5)

                    DeviceFirmwarePanel(
                        // Prefer the version read during the running sync
                        // session — it's read on the first BLE handshake
                        // so the panel populates the moment the device is
                        // discovered. firmwareUpdater.deviceInfo is the
                        // fallback after a successful OTA when we
                        // re-probe to verify the new version.
                        deviceInfo: sync.deviceInfo ?? firmwareUpdater.deviceInfo,
                        latest: releaseChecker.latest,
                        syncPhase: sync.phase,
                        updaterPhase: firmwareUpdater.phase,
                        onUpdate: { showingFirmwareUpdate = true })
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)

                    Rectangle()
                        .fill(Color.paperInk.opacity(0.12))
                        .frame(height: 0.5)

                    if sync.bookEntries.isEmpty {
                        prelaunchBody
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(sync.bookEntries) { entry in
                                    SyncBookRow(entry: entry)
                                    Rectangle()
                                        .fill(Color.paperRule.opacity(0.2))
                                        .frame(height: 0.5)
                                        .padding(.leading, 48)
                                }
                            }
                        }
                        .transition(.opacity)
                    }

                    Spacer(minLength: 0)

                    Rectangle()
                        .fill(Color.paperRule.opacity(0.35))
                        .frame(height: 0.5)
                        .padding(.horizontal, 24)

                    actionSection
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .padding(.bottom, 44)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("AirBook sync")
                        .font(.system(.subheadline, design: .serif).weight(.bold))
                        .foregroundStyle(Color.paperInk)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .font(.system(.subheadline, design: .serif))
                        .disabled(sync.phase.isActive || firmwareUpdater.phase.isActive)
                        .foregroundStyle((sync.phase.isActive || firmwareUpdater.phase.isActive)
                                            ? Color.paperRule : Color.paperInk)
                }
            }
            .toolbarBackground(Color.paperBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(sync.phase.isActive || firmwareUpdater.phase.isActive)
            .sheet(isPresented: $showingFirmwareUpdate) {
                if let release = releaseChecker.latest {
                    FirmwareUpdateView(release: release,
                                       currentDeviceVersion: firmwareUpdater.deviceInfo?.version)
                        .environment(firmwareUpdater)
                }
            }
            .task {
                // Fire-and-forget the GitHub Releases fetch — fails open
                // (the UI shows "Couldn't reach GitHub" but the book sync
                // still works).
                try? await releaseChecker.refresh()
            }
            .onAppear {
                // Auto-start only when nothing's in flight or visible — lets
                // the user reopen the sheet to read a previous summary
                // without retriggering a sync.
                if case .idle = sync.phase {
                    sync.start(store: store, readingStateStore: readingStateStore)
                }
            }
            .onDisappear { if sync.phase.isActive { sync.cancel() } }
        }
    }

    // MARK: Pre-launch / empty

    private var prelaunchBody: some View {
        VStack(spacing: 0) {
            Spacer()
            SyncIdleIcon(phase: sync.phase)
                .frame(height: 80)
            Spacer()
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actionSection: some View {
        switch sync.phase {
        case .idle:
            syncPrimaryButton("Sync Now") {
                sync.start(store: store, readingStateStore: readingStateStore)
            }

        case .scanning, .connecting, .handshake, .listing, .executing, .finalizing:
            ghostButton("Cancel") { sync.cancel() }

        case .done:
            syncPrimaryButton("Done") { dismiss() }

        case .cancelled, .error:
            VStack(spacing: 12) {
                syncPrimaryButton("Try Again") {
                    sync.reset()
                    sync.start(store: store, readingStateStore: readingStateStore)
                }
                ghostButton("Close") { dismiss() }
            }
        }
    }

    private func syncPrimaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(.headline, design: .serif))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.paperInk)
                .foregroundStyle(Color.paperBackground)
        }
    }

    private func ghostButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(.headline, design: .serif))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .foregroundStyle(Color.paperRule)
                .overlay(Rectangle().stroke(Color.paperRule.opacity(0.5), lineWidth: 0.8))
        }
    }
}

// MARK: - Status Header

struct SyncStatusHeader: View {
    let phase: SyncPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(phase.statusMessage)
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(headerColor)
                .animation(.none, value: phase)

            if case .executing(let step) = phase, step.bytesTotal > 0 {
                let p = Double(step.bytesTransferred) / Double(step.bytesTotal)
                ProgressView(value: max(0, min(1, p)))
                    .progressViewStyle(.linear)
                    .tint(Color.paperInk)
                    .scaleEffect(y: 1.4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerColor: Color {
        switch phase {
        case .error:     return Color.paperError
        case .cancelled: return Color.paperRule
        case .done:      return Color.paperInk
        default:         return Color.paperInk
        }
    }
}

// MARK: - Idle icon animation

struct SyncIdleIcon: View {
    let phase: SyncPhase
    @State private var animating = false

    var body: some View {
        Group {
            switch phase {
            case .idle:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(Color.paperRule)

            case .scanning:
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .stroke(Color.paperInk.opacity(animating ? 0 : 0.22), lineWidth: 1)
                            .frame(width: CGFloat(38 + i * 20), height: CGFloat(38 + i * 20))
                            .scaleEffect(animating ? 1.3 : 0.85)
                            .animation(
                                .easeOut(duration: 1.5).repeatForever(autoreverses: false)
                                    .delay(Double(i) * 0.42),
                                value: animating
                            )
                    }
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 22, weight: .ultraLight))
                        .foregroundStyle(Color.paperInk)
                }
                .onAppear { animating = true }
                .onDisappear { animating = false }

            case .connecting, .handshake, .listing:
                ProgressView()
                    .scaleEffect(1.8)
                    .tint(Color.paperInk)

            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .ultraLight))
                    .foregroundStyle(Color.paperInk)

            case .error:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(Color.paperError)

            case .cancelled:
                Image(systemName: "xmark")
                    .font(.system(size: 30, weight: .ultraLight))
                    .foregroundStyle(Color.paperRule)

            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Book Row

struct SyncBookRow: View {
    let entry: SyncBookEntry

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayTitle)
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)

                if case .uploading = entry.action {
                    ProgressView(value: entry.progress)
                        .progressViewStyle(.linear)
                        .tint(Color.paperInk)
                        .frame(maxWidth: .infinity)
                        .scaleEffect(y: 1.2)
                }
            }

            Spacer(minLength: 8)

            statusLabel
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .animation(.easeInOut(duration: 0.2), value: entry.action)
    }

    // MARK: Icon

    @ViewBuilder
    private var statusIcon: some View {
        switch entry.action {
        case .keep:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.paperRule)
        case .keepEntryOnly:
            Image(systemName: "circle.dotted")
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(Color.paperRule)
        case .willUpload:
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(Color.paperRule)
        case .uploading:
            ProgressView().scaleEffect(0.65).tint(Color.paperInk)
        case .uploaded:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.paperInk)
        case .willDeleteEntry:
            Image(systemName: "minus")
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(Color.paperError)
        case .deletingEntry:
            ProgressView().scaleEffect(0.65).tint(Color.paperError)
        case .entryDeleted:
            Image(systemName: "minus")
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(Color.paperRule)
        case .willRemoveFile:
            Image(systemName: "tray")
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(Color.paperRule)
        case .removingFile:
            ProgressView().scaleEffect(0.65).tint(Color.paperRule)
        case .fileRemoved:
            Image(systemName: "circle.dotted")
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(Color.paperRule)
        case .foreign:
            Image(systemName: "questionmark")
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(Color.paperRule)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.paperError)
        }
    }

    // MARK: Label

    @ViewBuilder
    private var statusLabel: some View {
        switch entry.action {
        case .keep:
            label("On device", color: Color.paperRule)
        case .keepEntryOnly:
            label("Entry only", color: Color.paperRule)
        case .willUpload:
            label("Pending", color: Color.paperRule)
        case .uploading:
            label("\(Int(entry.progress * 100))%", color: Color.paperInk, monospacedDigit: true)
        case .uploaded:
            label("Sent", color: Color.paperInk)
        case .willDeleteEntry:
            label("Remove", color: Color.paperError)
        case .deletingEntry:
            label("Removing", color: Color.paperError)
        case .entryDeleted:
            label("Removed", color: Color.paperRule)
        case .willRemoveFile:
            label("Free space", color: Color.paperRule)
        case .removingFile:
            label("Freeing", color: Color.paperRule)
        case .fileRemoved:
            label("Freed", color: Color.paperRule)
        case .foreign:
            label("Foreign", color: Color.paperRule)
        case .failed:
            label("Failed", color: Color.paperError)
        }
    }

    private func label(_ text: String, color: Color, monospacedDigit: Bool = false) -> some View {
        let base = Text(text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(color)
        return Group {
            if monospacedDigit { base.monospacedDigit() } else { base }
        }
    }

    private var titleColor: Color {
        switch entry.action {
        case .willDeleteEntry, .deletingEntry, .entryDeleted,
             .willRemoveFile, .removingFile, .fileRemoved,
             .foreign:
            return Color.paperRule
        case .failed:
            return Color.paperError
        default:
            return Color.paperInk
        }
    }
}

// MARK: - Device & Firmware panel
//
// Sits between the sync status header and the book list. Surfaces the
// device's firmware version and, when a newer release is on GitHub,
// offers a one-tap entry into the FirmwareUpdateView. Disabled while a
// book sync is in flight so we don't fight SyncManager for the same
// BLE peripheral.

private struct DeviceFirmwarePanel: View {
    /// Device identity. nil until the SyncManager's BLE handshake reads
    /// the Info characteristic, OR forever if the firmware predates Info
    /// support (in which case the searching state shows until the sync
    /// phase becomes done/error/cancelled, then we explain).
    let deviceInfo: DeviceFirmwareInfo?
    let latest: FirmwareReleaseInfo?
    /// Current SyncManager phase — drives whether we're still actively
    /// looking for the device.
    let syncPhase: SyncPhase
    /// FirmwareUpdateManager phase — used to disable the Update button
    /// while an OTA is in flight on a different sheet.
    let updaterPhase: FirmwareUpdatePhase
    let onUpdate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("DEVICE")
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .foregroundStyle(Color.paperRule)
                Spacer()
                if updaterPhase.isActive {
                    Text(updaterPhase.statusText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.paperRule)
                }
            }

            // The panel has three discrete shapes:
            //   1. searching — nothing known yet, sync still negotiating
            //   2. found — name + firmware version (+ optional Update CTA)
            //   3. unknown — sync ended without us reading the Info char
            //      (older firmware); explain what to do.
            switch panelState {
            case .searching:
                searchingRow
            case .found(let info):
                foundRow(info: info)
                if shouldOfferUpdate(for: info) { updateBanner(for: info) }
            case .legacyNoInfo:
                legacyRow
            }
        }
    }

    // MARK: Sub-rows

    private var searchingRow: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.6).tint(Color.paperInk)
            Text("Searching for CrossPoint…")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(Color.paperInk)
            Spacer()
        }
    }

    private func foundRow(info: DeviceFirmwareInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "cube")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(Color.paperInk)
            VStack(alignment: .leading, spacing: 2) {
                Text("CrossPoint AirBook")
                    .font(.system(.subheadline, design: .serif).weight(.bold))
                    .foregroundStyle(Color.paperInk)
                Text("Firmware \(info.version.isEmpty ? "—" : info.version)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
            }
            Spacer()
            if shouldOfferUpdate(for: info) {
                updateButton
            }
        }
    }

    private var legacyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(Color.paperRule)
                Text("Couldn't read device firmware")
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(Color.paperInk)
                Spacer()
            }
            Text("The reader is on an older build that doesn't report its version. Re-flash from the web tool to enable wireless updates.")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.paperRule)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Update banner / button

    private func shouldOfferUpdate(for info: DeviceFirmwareInfo) -> Bool {
        guard let latest else { return false }
        return latest.isNewerThan(info.version)
    }

    @ViewBuilder
    private var updateButton: some View {
        Button(action: onUpdate) {
            Text("Update")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(Color.paperBackground)
                .background(Color.paperInk)
        }
        .disabled(updaterPhase.isActive || syncPhase.isActive)
        .opacity((updaterPhase.isActive || syncPhase.isActive) ? 0.4 : 1)
    }

    private func updateBanner(for info: DeviceFirmwareInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(Color.paperInk)
            Text("Firmware update available: \(info.version) → \(latest?.version ?? "")")
                .font(.system(.caption, design: .serif))
                .foregroundStyle(Color.paperInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .overlay(Rectangle().stroke(Color.paperInk.opacity(0.35), lineWidth: 0.5))
    }

    // MARK: State decision

    private enum PanelState {
        case searching
        case found(DeviceFirmwareInfo)
        case legacyNoInfo
    }

    private var panelState: PanelState {
        if let info = deviceInfo { return .found(info) }
        // No info yet — are we still trying, or did sync wrap up without
        // ever reading it?
        switch syncPhase {
        case .scanning, .connecting, .handshake:
            return .searching
        case .listing, .executing, .finalizing:
            // We're past the handshake and Info char read should have
            // landed by now. If it didn't, the firmware predates Info
            // support. Don't lie about "Searching..." while a sync is
            // already running its file ops.
            return .legacyNoInfo
        case .done, .cancelled, .error:
            return .legacyNoInfo
        case .idle:
            return .searching
        }
    }
}
