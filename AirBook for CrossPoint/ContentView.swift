import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root Library View

struct ContentView: View {
    @Environment(BookStore.self) private var store
    @Environment(ReadingStateStore.self) private var readingStateStore
    @Environment(CollectionsStore.self) private var collectionsStore
    @Environment(MetadataLookupService.self) private var lookup
    @Environment(ZLibService.self) private var zlib
    @Environment(FirmwareUpdateManager.self) private var firmwareUpdater
    @Environment(FirmwareReleaseChecker.self) private var firmwareReleaseChecker
    @State private var showingPicker = false
    @State private var showingSync = false
    @State private var showingDiscover = false
    @State private var importErrorMessage: String?
    @State private var showingImportError = false
    @State private var scanner = DeviceScanner()
    // Shared with SyncView (sheet) AND BookCardView (grid) so per-book status
    // badges update live during an in-flight sync.
    @State private var sync = SyncManager()
    @State private var selectedBookID: UUID?
    @State private var query = LibraryQuery()
    @State private var showingDiagnostics = false

    private var visibleBooks: [Book] {
        query.apply(to: store.books,
                    readingStateStore: readingStateStore,
                    deviceStates: store.deviceStates)
    }

    private var availableFormats: [String] {
        Array(Set(store.books.map(\.ext))).sorted()
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.paperBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    masthead
                    connectionStatusBar

                    Rectangle()
                        .fill(Color.paperInk)
                        .frame(height: 1.5)

                    Rectangle()
                        .fill(Color.paperRule.opacity(0.35))
                        .frame(height: 0.5)
                        .padding(.top, 2.5)

                    if !store.books.isEmpty {
                        LibraryToolbar(query: $query,
                                       availableCollections: collectionsStore.collections,
                                       availableFormats: availableFormats)
                        Rectangle()
                            .fill(Color.paperRule.opacity(0.35))
                            .frame(height: 0.5)
                    }

                    Group {
                        if store.books.isEmpty {
                            EmptyLibraryView { showingPicker = true }
                                .transition(.opacity)
                        } else if visibleBooks.isEmpty {
                            NoMatchView { query = LibraryQuery() }
                                .transition(.opacity)
                        } else {
                            ScrollView {
                                LazyVGrid(columns: columns, spacing: 16) {
                                    ForEach(visibleBooks) { book in
                                        Button {
                                            selectedBookID = book.id
                                        } label: {
                                            BookCardView(book: book)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button {
                                                selectedBookID = book.id
                                            } label: {
                                                Label("Show Details", systemImage: "info.circle")
                                            }
                                            if store.hasFileOnDevice(book) {
                                                Button {
                                                    store.queueFileRemoval(book)
                                                } label: {
                                                    Label("Free Space on Device",
                                                          systemImage: "tray.and.arrow.down")
                                                }
                                            }
                                            Button(role: .destructive) {
                                                store.deleteBook(book)
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                                .padding(.bottom, 40)
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: store.books.isEmpty)
                    .animation(.easeInOut(duration: 0.2), value: visibleBooks.count)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { scanner.startScan() }
            .onDisappear { scanner.stopScan() }
        }
        .environment(sync)
        .sheet(isPresented: $showingSync) {
            SyncView()
                .environment(store)
                .environment(sync)
                .environment(readingStateStore)
                .environment(firmwareUpdater)
                .environment(firmwareReleaseChecker)
        }
        .sheet(isPresented: $showingDiscover) {
            DiscoverView()
                .environment(store)
                .environment(sync)
                .environment(readingStateStore)
                .environment(collectionsStore)
                .environment(lookup)
                .environment(zlib)
        }
        .sheet(isPresented: $showingPicker) {
            DocumentPickerView { url in
                do {
                    _ = try store.importBook(from: url)
                } catch {
                    importErrorMessage = error.localizedDescription
                    showingImportError = true
                }
            }
        }
        .sheet(item: $selectedBookID) { id in
            BookDetailView(bookID: id)
                .environment(store)
                .environment(sync)
                .environment(readingStateStore)
                .environment(collectionsStore)
                .environment(lookup)
        }
        .sheet(isPresented: $showingDiagnostics) {
            SyncDiagnosticsView()
                .environment(sync)
        }
        .alert("Import Failed", isPresented: $showingImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "Unknown error")
        }
    }

    // MARK: Masthead

    private var masthead: some View {
        HStack(alignment: .center, spacing: 8) {
            // Mixed-weight wordmark: "Air" thin/light, "Book" bold —
            // gives the masthead a magazine-style lockup while staying in
            // the serif family used everywhere else.
            (Text("Air").font(.system(.title, design: .serif).weight(.light))
                + Text("Book").font(.system(.title, design: .serif).weight(.bold)))
                .foregroundStyle(Color.paperInk)
                .onLongPressGesture { showingDiagnostics = true }

            // Connection status dot
            Circle()
                .fill(scanner.isNearby ? Color.paperInk : Color.paperRule.opacity(0.35))
                .frame(width: 5, height: 5)
                .animation(.easeInOut(duration: 0.4), value: scanner.isNearby)

            Spacer()

            // Discover (search & download from Z-Library)
            Button { showingDiscover = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.paperInk)
                    .frame(width: 30, height: 30)
                    .overlay(Rectangle().stroke(Color.paperInk, lineWidth: 0.8))
            }

            // Sync button
            Button { showingSync = true } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.paperInk)
                    .frame(width: 30, height: 30)
                    .overlay(Rectangle().stroke(Color.paperInk, lineWidth: 0.8))
            }

            // Add book button
            Button { showingPicker = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.paperInk)
                    .frame(width: 30, height: 30)
                    .overlay(Rectangle().stroke(Color.paperInk, lineWidth: 0.8))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Connection status bar

    @ViewBuilder
    private var connectionStatusBar: some View {
        if scanner.isNearby || scanner.isScanning {
            HStack(spacing: 6) {
                if scanner.isScanning && !scanner.isNearby {
                    ProgressView().scaleEffect(0.5).tint(Color.paperRule)
                }
                Text(scanner.isNearby ? "CrossPoint nearby" : "Searching...")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.easeInOut(duration: 0.3), value: scanner.isNearby)
        }
    }
}

// MARK: - Book Card

struct BookCardView: View {
    @Environment(BookStore.self) private var store
    @Environment(SyncManager.self) private var sync
    let book: Book

    var body: some View {
        let status = store.libraryStatus(for: book, sync: sync)
        let author = book.metadata.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        VStack(alignment: .leading, spacing: 6) {
            BookCoverView(book: book)

            VStack(alignment: .leading, spacing: 2) {
                Text(book.displayTitle)
                    .font(.system(.caption, design: .serif).weight(.bold))
                    .lineLimit(2, reservesSpace: true)
                    .foregroundStyle(Color.paperInk)
                    .multilineTextAlignment(.leading)

                Text(author.isEmpty ? " " : author)
                    .font(.system(.caption2, design: .serif))
                    .foregroundStyle(Color.paperRule)
                    .lineLimit(1, reservesSpace: true)

                HStack(spacing: 4) {
                    Text(ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(Color.paperRule)

                    Spacer(minLength: 0)

                    BookStatusBadge(status: status)
                        .animation(.easeInOut(duration: 0.2), value: status)
                }
                .frame(height: 14)
            }
            .padding(.horizontal, 1)
        }
    }
}

// MARK: - Book Cover

struct BookCoverView: View {
    @Environment(BookStore.self) private var store
    let book: Book

    private var topGray: Double {
        let hash = book.filename.unicodeScalars.reduce(UInt32(0)) { ($0 &* 31) &+ $1.value }
        let values: [Double] = [0.94, 0.84, 0.68, 0.50]
        return values[Int(hash % 4)]
    }

    private var coverImage: UIImage? {
        guard let assetID = book.metadata.coverAssetID else { return nil }
        let url = store.coverFileURL(for: assetID)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack(alignment: .bottom) {
                        Color(white: topGray)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(book.ext.uppercased())
                                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                                .foregroundStyle(Color(white: 0.65))

                            Text(book.displayTitle)
                                .font(.system(size: 13, weight: .bold, design: .serif))
                                .foregroundStyle(Color(white: 0.95))
                                .lineLimit(3)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(white: 0.07))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.paperInk.opacity(0.14), lineWidth: 0.7)
        )
    }
}

// MARK: - UUID + Identifiable sheet support

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

// MARK: - No match (filter rejects everything)

struct NoMatchView: View {
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(Color.paperRule)
            Text("No books match these filters.")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(Color.paperInk)
            Button("Clear all", action: onReset)
                .font(.system(.subheadline, design: .serif).weight(.bold))
                .foregroundStyle(Color.paperInk)
            Spacer()
        }
    }
}

// MARK: - Empty State

struct EmptyLibraryView: View {
    let onAdd: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 0) {
                Text("Your Library")
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .foregroundStyle(Color.paperInk)

                Rectangle()
                    .fill(Color.paperInk)
                    .frame(height: 1)
                    .padding(.top, 10)

                Text("No books yet. Import EPUB, TXT, BMP or XTC files to send them wirelessly to your CrossPoint.")
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(Color.paperRule)
                    .padding(.top, 12)

                Button(action: onAdd) {
                    Text("Add First Book")
                        .font(.system(.headline, design: .serif))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.paperInk)
                        .foregroundStyle(Color.paperBackground)
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 28)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)

            Spacer()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45).delay(0.05)) { appeared = true }
        }
    }
}

// MARK: - Document Picker

struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .text, .item])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

// MARK: - Design Tokens

extension Color {
    static let paperBackground = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1)
            : UIColor(red: 0.976, green: 0.969, blue: 0.957, alpha: 1)
    })

    static let paperInk = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.91, green: 0.90, blue: 0.88, alpha: 1)
            : UIColor(red: 0.08, green: 0.07, blue: 0.06, alpha: 1)
    })

    static let paperRule = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.48, green: 0.46, blue: 0.44, alpha: 1)
            : UIColor(red: 0.50, green: 0.48, blue: 0.45, alpha: 1)
    })

    // Muted amber — only for errors
    static let paperError = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.62, green: 0.44, blue: 0.16, alpha: 1)
            : UIColor(red: 0.48, green: 0.28, blue: 0.05, alpha: 1)
    })
}
