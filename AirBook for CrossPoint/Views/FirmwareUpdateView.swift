import SwiftUI

// MARK: - Firmware Update Sheet
//
// Drives the FirmwareUpdateManager and renders progress / success / fail
// in the same paper aesthetic as the rest of the app. Reachable from the
// Device & Updates section of SyncView when an update is available.

struct FirmwareUpdateView: View {
    let release: FirmwareReleaseInfo
    let currentDeviceVersion: String?

    @Environment(FirmwareUpdateManager.self) private var updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.paperBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    Rectangle().fill(Color.paperInk.opacity(0.12)).frame(height: 0.5)

                    ScrollView {
                        VStack(spacing: 22) {
                            versionsSection
                            phaseSection
                            if !release.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                changelogSection
                            }
                            stepsSection
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 22)
                        .padding(.bottom, 24)
                    }

                    Rectangle().fill(Color.paperRule.opacity(0.35)).frame(height: 0.5)
                        .padding(.horizontal, 24)

                    actionSection
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .padding(.bottom, 44)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Firmware update")
                        .font(.system(.subheadline, design: .serif).weight(.bold))
                        .foregroundStyle(Color.paperInk)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .font(.system(.subheadline, design: .serif))
                        .disabled(updater.phase.isActive)
                        .foregroundStyle(updater.phase.isActive ? Color.paperRule : Color.paperInk)
                }
            }
            .toolbarBackground(Color.paperBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(updater.phase.isActive)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            Text(release.tag)
                .font(.system(.title3, design: .serif).weight(.bold))
                .foregroundStyle(Color.paperInk)
            if let date = release.publishedAt {
                Text(date.formatted(.dateTime.day().month().year()))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    // MARK: Versions section

    private var versionsSection: some View {
        VStack(spacing: 6) {
            versionRow(label: "Installed",
                       value: currentDeviceVersion ?? "Unknown")
            paperRule
            versionRow(label: "Available",
                       value: release.version)
            paperRule
            HStack(spacing: 8) {
                Text("Size")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
                    .frame(width: 84, alignment: .leading)
                Text(ByteCountFormatter.string(fromByteCount: release.sizeBytes, countStyle: .file))
                    .font(.system(.footnote, design: .serif))
                    .foregroundStyle(Color.paperInk)
                Spacer()
            }
        }
    }

    private func versionRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.paperRule)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.system(.footnote, design: .serif).weight(.medium))
                .foregroundStyle(Color.paperInk)
            Spacer()
        }
    }

    // MARK: Phase section (progress)

    @ViewBuilder
    private var phaseSection: some View {
        switch updater.phase {
        case .idle:
            EmptyView()

        case .downloading(let received, let total):
            phasePanel(
                title: updater.phase.statusText,
                fraction: total > 0 ? Double(received) / Double(total) : nil,
                detail: total > 0
                    ? "\(formattedBytes(received)) of \(formattedBytes(total))"
                    : nil)

        case .scanning, .connecting, .discovering, .ready:
            phasePanel(title: updater.phase.statusText, fraction: nil, detail: nil)

        case .sending(let done, let total):
            phasePanel(
                title: "Sending firmware to device",
                fraction: total > 0 ? Double(done) / Double(total) : nil,
                detail: "\(formattedBytes(done)) of \(formattedBytes(total))")

        case .verifying, .flashing:
            phasePanel(title: updater.phase.statusText,
                       fraction: nil,
                       detail: "Keep the CrossPoint nearby — do not turn it off.")

        case .rebooting(let s):
            phasePanel(title: "Device rebooting",
                       fraction: nil,
                       detail: s > 0 ? "Verifying in \(s)s..." : "Verifying...")

        case .success(let v):
            successPanel(version: v)

        case .failed(let msg):
            failurePanel(message: msg)
        }
    }

    private func phasePanel(title: String, fraction: Double?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6).tint(Color.paperInk)
                Text(title)
                    .font(.system(.subheadline, design: .serif).weight(.bold))
                    .foregroundStyle(Color.paperInk)
                Spacer()
                if let fraction {
                    Text("\(Int((fraction.clamped() * 100).rounded()))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.paperInk)
                        .monospacedDigit()
                }
            }
            if let fraction {
                progressBar(fraction)
            } else {
                indeterminateBar
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(Color.paperInk.opacity(0.18), lineWidth: 0.5))
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.paperRule.opacity(0.18))
                Rectangle()
                    .fill(Color.paperInk)
                    .frame(width: geo.size.width * CGFloat(fraction.clamped()))
                    .animation(.easeInOut(duration: 0.2), value: fraction)
            }
        }
        .frame(height: 6)
    }

    private var indeterminateBar: some View {
        // Static striped fill — we don't bounce the bar because the
        // verifying/flashing phases are quick enough that motion would
        // distract more than it'd inform.
        Rectangle()
            .fill(Color.paperRule.opacity(0.18))
            .overlay(
                GeometryReader { geo in
                    HStack(spacing: 6) {
                        ForEach(0..<8, id: \.self) { _ in
                            Rectangle().fill(Color.paperInk.opacity(0.4))
                                .frame(width: 8)
                        }
                    }
                    .frame(width: geo.size.width, alignment: .leading)
                    .clipped()
                })
            .frame(height: 6)
    }

    private func successPanel(version: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.paperInk)
                Text("Update complete")
                    .font(.system(.subheadline, design: .serif).weight(.bold))
                    .foregroundStyle(Color.paperInk)
                Spacer()
            }
            if let version {
                Text("CrossPoint is now running \(version).")
                    .font(.system(.caption, design: .serif))
                    .foregroundStyle(Color.paperInk)
            } else {
                Text("CrossPoint restarted with the new firmware.")
                    .font(.system(.caption, design: .serif))
                    .foregroundStyle(Color.paperInk)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(Color.paperInk.opacity(0.4), lineWidth: 0.6))
    }

    private func failurePanel(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.paperError)
                Text("Update failed")
                    .font(.system(.subheadline, design: .serif).weight(.bold))
                    .foregroundStyle(Color.paperError)
                Spacer()
            }
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.paperError)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your CrossPoint kept its old firmware — it's safe to try again.")
                .font(.system(.caption, design: .serif))
                .foregroundStyle(Color.paperRule)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(Color.paperError.opacity(0.5), lineWidth: 0.6))
    }

    // MARK: Changelog

    private var changelogSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What's new".uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.paperRule)
            // Trimmed body keeps the modal scannable — the full release
            // text lives one tap away on GitHub if the user wants the
            // PR-by-PR breakdown.
            Text(release.body.prefix(1200) + (release.body.count > 1200 ? "…" : ""))
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(Color.paperInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Steps explainer

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How it works".uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.paperRule)
            step(number: "1", text: "iPhone downloads the firmware from GitHub.")
            step(number: "2", text: "Connects to your CrossPoint over Bluetooth.")
            step(number: "3", text: "Streams the firmware (~2 minutes).")
            step(number: "4", text: "CrossPoint verifies and installs it.")
            step(number: "5", text: "Device reboots itself. Wait ~20s; the app reconnects to confirm the new version.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(Color.paperRule)
                .frame(width: 16, alignment: .leading)
            Text(text)
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(Color.paperInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actionSection: some View {
        switch updater.phase {
        case .idle:
            primaryButton("Update firmware") {
                updater.startUpdate(to: release)
            }
        case .downloading, .scanning, .connecting, .discovering, .ready,
             .sending, .verifying, .flashing, .rebooting:
            ghostButton(updater.phase == .verifying || updater.phase == .flashing
                            ? "Cancel (unavailable)" : "Cancel") {
                updater.cancel()
            }
            .disabled(updater.phase == .verifying || updater.phase == .flashing)
        case .success:
            primaryButton("Done") { dismiss() }
        case .failed:
            VStack(spacing: 12) {
                primaryButton("Try Again") {
                    updater.resetToIdle()
                    updater.startUpdate(to: release)
                }
                ghostButton("Close") { dismiss() }
            }
        }
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
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

    private var paperRule: some View {
        Rectangle().fill(Color.paperRule.opacity(0.25)).frame(height: 0.5)
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

// MARK: - Small clamp helper

private extension Double {
    func clamped() -> Double { Swift.max(0, Swift.min(1, self)) }
}
