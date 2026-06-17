import SwiftUI
import UniformTypeIdentifiers

// MARK: - Device Files Browser

struct DeviceFilesView: View {
    @Environment(DeviceFileBrowser.self) private var browser
    @Environment(\.dismiss) private var dismiss

    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.paperBackground.ignoresSafeArea()
                content
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Device files")
                        .font(.system(.subheadline, design: .serif).weight(.bold))
                        .foregroundStyle(Color.paperInk)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        browser.close()
                        dismiss()
                    }
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(Color.paperInk)
                }
            }
            .toolbarBackground(Color.paperBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: Binding(
                get: { shareURL.map { ShareItem(url: $0) } },
                set: { shareURL = $0?.url })
            ) { item in
                ShareSheet(items: [item.url])
            }
            .onAppear {
                if case .idle = browser.phase { browser.start() }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch browser.phase {
        case .idle, .scanning, .connecting, .discovering:
            connectingState(detail: nil)
        case .listing(let path):
            connectingState(detail: "Reading \(displayPath(path))…")
        case .ready(let path, let entries):
            VStack(spacing: 0) {
                if !path.isEmpty { breadcrumbBar(path) }
                fileList(entries)
            }
        case .downloading(let entry, let done, let total):
            downloadingState(entry: entry, done: done, total: total)
        case .downloaded(let entry, let url):
            downloadedState(entry: entry, url: url)
        case .failed(let message):
            failureState(message)
        }
    }

    private func displayPath(_ path: String) -> String {
        path.isEmpty ? "/AirBook" : "/AirBook/\(path)"
    }

    private func breadcrumbBar(_ path: String) -> some View {
        HStack(spacing: 10) {
            Button {
                browser.navigateUp()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(Color.paperInk)
                    .frame(width: 22, height: 22)
            }
            Text(displayPath(path))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.paperRule)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.paperRule.opacity(0.25)).frame(height: 0.5)
        }
    }

    private func connectingState(detail: String?) -> some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().tint(Color.paperInk)
            Text(detail ?? "Connecting to CrossPoint…")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(Color.paperInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
    }

    private func fileList(_ entries: [DeviceFileEntry]) -> some View {
        Group {
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 32, weight: .ultraLight))
                        .foregroundStyle(Color.paperRule)
                    Text("No files on the device")
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(Color.paperRule)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            VStack(spacing: 0) {
                                row(entry: entry)
                                Rectangle().fill(Color.paperRule.opacity(0.2))
                                    .frame(height: 0.5)
                                    .padding(.leading, 20)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func row(entry: DeviceFileEntry) -> some View {
        Button {
            if entry.isDirectory {
                browser.navigate(into: entry)
            } else {
                browser.download(entry)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: entry))
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(Color.paperInk)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(Color.paperInk)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(entry.isDirectory
                            ? "Folder"
                            : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.paperRule)
                }
                Spacer()
                Image(systemName: entry.isDirectory ? "chevron.right" : "arrow.down.circle")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(Color.paperRule)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconName(for entry: DeviceFileEntry) -> String {
        if entry.isDirectory { return "folder" }
        let lower = entry.name.lowercased()
        if lower.hasSuffix(".epub") { return "book.closed" }
        if lower.hasSuffix(".bmp") || lower.hasSuffix(".jpg") || lower.hasSuffix(".png") {
            return "photo"
        }
        if lower.hasSuffix(".txt") { return "doc.text" }
        if lower.hasSuffix(".xtc") || lower.hasSuffix(".xtch") { return "book" }
        return "doc"
    }

    // MARK: - Download states

    private func downloadingState(entry: DeviceFileEntry, done: Int64, total: Int64) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(Color.paperInk)
            Text(entry.name)
                .font(.system(.subheadline, design: .serif).weight(.bold))
                .foregroundStyle(Color.paperInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            let fraction = total > 0 ? Double(done) / Double(total) : 0
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.paperRule.opacity(0.18))
                        Rectangle().fill(Color.paperInk)
                            .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
                            .animation(.linear(duration: 0.5), value: fraction)
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(progressBytes(done: done, total: total))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.paperRule)
                    Spacer()
                    Text("\(Int(fraction * 100))%")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.paperInk)
                }
            }
            .padding(.horizontal, 32)
            Button {
                browser.cancelDownload()
            } label: {
                Text("Cancel")
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(Color.paperRule)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(Rectangle().stroke(Color.paperRule.opacity(0.5), lineWidth: 0.8))
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)
            Spacer()
        }
    }

    private func downloadedState(entry: DeviceFileEntry, url: URL) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(Color.paperInk)
            Text("Got \(entry.name)")
                .font(.system(.subheadline, design: .serif).weight(.bold))
                .foregroundStyle(Color.paperInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.paperRule)

            VStack(spacing: 10) {
                Button {
                    shareURL = url
                } label: {
                    Text("Share")
                        .font(.system(.headline, design: .serif))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.paperInk)
                        .foregroundStyle(Color.paperBackground)
                }
                Button {
                    browser.start()
                } label: {
                    Text("Browse more")
                        .font(.system(.subheadline, design: .serif))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(Color.paperRule)
                        .overlay(Rectangle().stroke(Color.paperRule.opacity(0.5), lineWidth: 0.8))
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
            Spacer()
        }
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(Color.paperError)
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.paperError)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                browser.start()
            } label: {
                Text("Try again")
                    .font(.system(.headline, design: .serif))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.paperInk)
                    .foregroundStyle(Color.paperBackground)
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)
            Spacer()
        }
    }

    private func progressBytes(done: Int64, total: Int64) -> String {
        let d = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
        let t = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(d) / \(t)"
    }
}

// MARK: - Share sheet bridge

private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
