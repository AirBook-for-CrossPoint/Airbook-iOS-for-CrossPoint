import SwiftUI

// MARK: - Book Detail View
//
// Sheet shown when the user taps a card. Surfaces title/author editing,
// online metadata lookup, on-device status with the free-space action, a
// summary of reading state pulled from ReadingStateStore, and the
// destructive "delete from library" path.

struct BookDetailView: View {
    let bookID: UUID

    @Environment(BookStore.self) private var store
    @Environment(ReadingStateStore.self) private var readingStateStore
    @Environment(CollectionsStore.self) private var collectionsStore
    @Environment(MetadataLookupService.self) private var lookup
    @Environment(SyncManager.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var editTitle = ""
    @State private var editAuthor = ""
    @State private var editPublisher = ""
    @State private var editYear = ""
    @State private var editLanguage = ""
    @State private var editISBN = ""
    @State private var editSynopsis = ""
    @State private var showingLookup = false
    @State private var showingDeleteConfirm = false

    private var book: Book? { store.books.first(where: { $0.id == bookID }) }

    var body: some View {
        // @Observable observation tripwire: ReadingStateStore tracks its
        // cache via the `revision` counter (the dict itself is @Observation
        // Ignored to keep tracking cheap). Body must touch `revision` so
        // collection/highlight/bookmark mutations re-render the detail
        // sections instantly instead of waiting for some other dependency
        // to invalidate the view.
        _ = readingStateStore.revision

        return NavigationStack {
            ZStack {
                Color.paperBackground.ignoresSafeArea()

                if let book {
                    ScrollView {
                        VStack(spacing: 22) {
                            coverSection(book: book)
                            titleSection(book: book)
                            if isEditing {
                                editFactsSection
                            } else {
                                factsSection(book: book)
                                synopsisSection(book: book)
                            }
                            lookupSection(book: book)
                            collectionsSection(book: book)
                            deviceSection(book: book)
                            readingStateSection(book: book)
                            highlightsSection(book: book)
                            destructiveSection(book: book)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .padding(.bottom, 40)
                    }
                } else {
                    VStack {
                        Spacer()
                        Text("Book not found")
                            .font(.system(.subheadline, design: .serif))
                            .foregroundStyle(Color.paperRule)
                        Spacer()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(Color.paperInk)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isEditing {
                        Button("Save") { saveEdits() }
                            .font(.system(.subheadline, design: .serif).weight(.bold))
                            .foregroundStyle(Color.paperInk)
                    } else if book != nil {
                        Button("Edit") { startEditing() }
                            .font(.system(.subheadline, design: .serif))
                            .foregroundStyle(Color.paperInk)
                    }
                }
            }
            .toolbarBackground(Color.paperBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showingLookup) {
            if let book {
                MetadataLookupSheet(
                    initialQuery: MetadataQuery(
                        title: book.metadata.title ?? book.displayTitle,
                        author: book.metadata.author,
                        isbn: book.metadata.isbn),
                    onSelect: { candidate in
                        applyLookup(candidate, to: book)
                    })
                .environment(lookup)
                .environment(store)
            }
        }
        .alert("Delete from Library?",
               isPresented: $showingDeleteConfirm,
               actions: {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let book {
                    store.deleteBook(book)
                    readingStateStore.purge(bookID: book.id)
                    dismiss()
                }
            }
        }, message: {
            Text("The file will be removed from this device. The device entry, if any, will be deleted at the next sync.")
        })
    }

    // MARK: Sections

    private func coverSection(book: Book) -> some View {
        BookCoverView(book: book)
            .frame(width: 150)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    @ViewBuilder
    private func titleSection(book: Book) -> some View {
        VStack(spacing: 6) {
            if isEditing {
                TextField("Title", text: $editTitle)
                    .font(.system(.title3, design: .serif).weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.paperInk)
                TextField("Author", text: $editAuthor)
                    .font(.system(.subheadline, design: .serif))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.paperRule)
            } else {
                Text(book.displayTitle)
                    .font(.system(.title3, design: .serif).weight(.bold))
                    .foregroundStyle(Color.paperInk)
                    .multilineTextAlignment(.center)
                if let author = book.metadata.author, !author.isEmpty {
                    Text(author)
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(Color.paperRule)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func factsSection(book: Book) -> some View {
        VStack(spacing: 8) {
            paperRule
            VStack(spacing: 4) {
                if let publisher = book.metadata.publisher, !publisher.isEmpty {
                    factRow("Publisher", publisher)
                }
                if let year = book.metadata.publishedYear {
                    factRow("Published", String(year))
                }
                if let language = book.metadata.language, !language.isEmpty {
                    factRow("Language", language)
                }
                if let isbn = book.metadata.isbn, !isbn.isEmpty {
                    factRow("ISBN", isbn)
                }
                if let pages = book.metadata.pageCountEstimate {
                    factRow("Pages", "\(pages)")
                }
                factRow("Format", book.ext.uppercased())
                factRow("Size", ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file))
            }
            paperRule
        }
    }

    @ViewBuilder
    private func synopsisSection(book: Book) -> some View {
        if let synopsis = book.metadata.synopsis, !synopsis.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Synopsis")
                Text(synopsis)
                    .font(.system(.footnote, design: .serif))
                    .foregroundStyle(Color.paperInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var editFactsSection: some View {
        VStack(spacing: 10) {
            paperRule
            editRow("Publisher", text: $editPublisher)
            editRow("Year", text: $editYear, keyboard: .numberPad)
            editRow("Language", text: $editLanguage)
            editRow("ISBN", text: $editISBN, keyboard: .numbersAndPunctuation)
            VStack(alignment: .leading, spacing: 4) {
                Text("Synopsis")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
                TextEditor(text: $editSynopsis)
                    .font(.system(.footnote, design: .serif))
                    .foregroundStyle(Color.paperInk)
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .background(Color.paperBackground)
                    .overlay(Rectangle().stroke(Color.paperRule.opacity(0.35), lineWidth: 0.5))
            }
            paperRule
        }
    }

    private func lookupSection(book: Book) -> some View {
        Button { showingLookup = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                Text("Look up metadata online")
                    .font(.system(.subheadline, design: .serif))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(Color.paperBackground)
            .background(Color.paperInk)
        }
    }

    private func collectionsSection(book: Book) -> some View {
        let state = readingStateStore.state(for: book.id)
        let assigned = state.collections
        let available = collectionsStore.collections.filter { !assigned.contains($0.name) }

        return VStack(spacing: 6) {
            sectionLabel("Collections")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(assigned, id: \.self) { name in
                        Button {
                            removeCollection(name, from: book)
                        } label: {
                            HStack(spacing: 4) {
                                Text(name)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(Color.paperBackground)
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(Color.paperBackground)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.paperInk)
                        }
                    }
                    Menu {
                        if available.isEmpty {
                            Text("No more collections — create one in Manage.")
                        } else {
                            ForEach(available) { c in
                                Button(c.name) { addCollection(c.name, to: book) }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .medium))
                            Text("Tag")
                                .font(.system(.caption2, design: .monospaced))
                        }
                        .foregroundStyle(Color.paperInk)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .overlay(Rectangle().stroke(Color.paperInk, lineWidth: 0.6))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addCollection(_ name: String, to book: Book) {
        var state = readingStateStore.state(for: book.id)
        if !state.collections.contains(name) {
            state.collections.append(name)
            readingStateStore.update(state)
        }
    }

    private func removeCollection(_ name: String, from book: Book) {
        var state = readingStateStore.state(for: book.id)
        state.collections.removeAll { $0 == name }
        readingStateStore.update(state)
    }

    private func deviceSection(book: Book) -> some View {
        let status = store.libraryStatus(for: book, sync: sync)
        return VStack(alignment: .leading, spacing: 10) {
            sectionLabel("On Device")
            HStack(spacing: 10) {
                BookStatusBadge(status: status, iconSize: 14)
                Text(statusText(status))
                    .font(.system(.footnote, design: .serif))
                    .foregroundStyle(Color.paperInk)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().stroke(Color.paperRule.opacity(0.35), lineWidth: 0.5))

            if status == .syncedFull {
                Button {
                    store.queueFileRemoval(book)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 11, weight: .light))
                        Text("Free file on device")
                            .font(.system(.footnote, design: .serif))
                    }
                    .foregroundStyle(Color.paperRule)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .overlay(Rectangle().stroke(Color.paperRule.opacity(0.4), lineWidth: 0.8))
                }
            } else if store.isFileRemovalQueued(book) {
                HStack {
                    Text("Queued to free at next sync")
                        .font(.system(.footnote, design: .serif))
                        .foregroundStyle(Color.paperRule)
                    Spacer()
                    Button("Undo") { store.unqueueFileRemoval(book) }
                        .font(.system(.footnote, design: .serif).weight(.bold))
                        .foregroundStyle(Color.paperInk)
                }
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readingStateSection(book: Book) -> some View {
        let state = readingStateStore.state(for: book.id)
        return VStack(spacing: 6) {
            sectionLabel("Reading State")
            HStack(spacing: 16) {
                statBlock("Progress",
                          value: state.progress.map { "\(Int($0.percentage * 100))%" } ?? "—")
                statBlock("Bookmarks", value: "\(state.bookmarks.count)")
                statBlock("Highlights", value: "\(state.highlights.count)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func highlightsSection(book: Book) -> some View {
        let state = readingStateStore.state(for: book.id)
        let highlights = state.highlights

        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Highlights")

            if highlights.isEmpty {
                Text("Highlights you make on your CrossPoint will appear here after the next sync.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(highlights) { hl in
                        VStack(spacing: 0) {
                            highlightRow(hl, book: book)
                            Rectangle().fill(Color.paperRule.opacity(0.2)).frame(height: 0.5)
                        }
                    }
                }
            }
        }
    }

    private func highlightRow(_ hl: HighlightRecord, book: Book) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(highlightSwatch(hl.colorTag))
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                if !hl.snippet.isEmpty {
                    Text(hl.snippet)
                        .font(.system(.footnote, design: .serif))
                        .foregroundStyle(Color.paperInk)
                        .lineLimit(3)
                } else {
                    Text(hl.xpathStart)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.paperRule)
                        .lineLimit(1)
                }
                if let note = hl.note, !note.isEmpty {
                    Text("Note: \(note)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.paperRule)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button {
                removeHighlight(id: hl.id, book: book)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .light))
                    .foregroundStyle(Color.paperRule)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func highlightSwatch(_ color: HighlightColor) -> Color {
        switch color {
        case .yellow: return Color(red: 0.85, green: 0.75, blue: 0.32)
        case .blue:   return Color(red: 0.32, green: 0.55, blue: 0.78)
        case .pink:   return Color(red: 0.80, green: 0.45, blue: 0.62)
        case .green:  return Color(red: 0.42, green: 0.65, blue: 0.42)
        }
    }

    private func removeHighlight(id: UUID, book: Book) {
        var state = readingStateStore.state(for: book.id)
        state.highlights.removeAll { $0.id == id }
        var flags = state.dirtyFlags
        flags.insert(.highlights)
        state.dirtyFlags = flags
        readingStateStore.update(state)
    }

    private func destructiveSection(book: Book) -> some View {
        Button(role: .destructive) {
            showingDeleteConfirm = true
        } label: {
            Text("Delete from Library")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(Color.paperError)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(Rectangle().stroke(Color.paperError.opacity(0.5), lineWidth: 0.8))
        }
        .padding(.top, 12)
    }

    // MARK: Small bits

    private var paperRule: some View {
        Rectangle().fill(Color.paperRule.opacity(0.35)).frame(height: 0.5)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .foregroundStyle(Color.paperRule)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.paperRule)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(Color.paperInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func editRow(_ label: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.paperRule)
                .frame(width: 80, alignment: .leading)
            TextField(label, text: text)
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(Color.paperInk)
                .keyboardType(keyboard)
                .padding(.vertical, 6)
                .overlay(Rectangle().fill(Color.paperRule.opacity(0.35)).frame(height: 0.5), alignment: .bottom)
        }
    }

    private func statBlock(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(Color.paperInk)
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.paperRule)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusText(_ status: BookLibraryStatus) -> String {
        switch status {
        case .notOnDevice: return "Not on device"
        case .uploading(let p): return "Uploading \(Int(p * 100))%"
        case .syncedFull: return "Synced"
        case .syncedEntryOnly: return "Entry only (file freed)"
        case .foreign: return "Foreign entry"
        case .queuedForUpload: return "Queued for upload"
        case .queuedForFileRemoval: return "Free space queued"
        case .queuedForEntryDeletion: return "Removal queued"
        case .failed(let m): return "Failed: \(m)"
        case .unknown: return "Unknown"
        }
    }

    // MARK: Actions

    private func startEditing() {
        guard let book else { return }
        editTitle = book.metadata.title ?? book.displayTitle
        editAuthor = book.metadata.author ?? ""
        editPublisher = book.metadata.publisher ?? ""
        editYear = book.metadata.publishedYear.map(String.init) ?? ""
        editLanguage = book.metadata.language ?? ""
        editISBN = book.metadata.isbn ?? ""
        editSynopsis = book.metadata.synopsis ?? ""
        isEditing = true
    }

    private func saveEdits() {
        guard let book else { return }
        let updated = BookMetadata(
            title: editTitle.isEmpty ? nil : editTitle,
            author: editAuthor.isEmpty ? nil : editAuthor,
            publisher: editPublisher.isEmpty ? nil : editPublisher,
            publishedYear: Int(editYear),
            language: editLanguage.isEmpty ? nil : editLanguage,
            isbn: editISBN.isEmpty ? nil : editISBN,
            synopsis: editSynopsis.isEmpty ? nil : editSynopsis,
            pageCountEstimate: book.metadata.pageCountEstimate,
            coverAssetID: book.metadata.coverAssetID,
            source: .manual,
            fetchedAt: Date())
        store.updateMetadata(updated, for: book)
        isEditing = false
    }

    private func applyLookup(_ candidate: MetadataCandidate, to book: Book) {
        // Synchronous metadata write first so the UI reflects the choice
        // immediately; cover download runs in the background.
        let source: MetadataSource = {
            switch candidate.provider {
            case .googleBooks: return .googleBooks
            case .openLibrary: return .openLibrary
            case .iTunes:      return .iTunes
            }
        }()
        let updated = BookMetadata(
            title: candidate.title,
            author: candidate.authors.isEmpty ? book.metadata.author : candidate.authors.joined(separator: ", "),
            publisher: candidate.publisher ?? book.metadata.publisher,
            publishedYear: candidate.publishedYear ?? book.metadata.publishedYear,
            language: candidate.language ?? book.metadata.language,
            isbn: candidate.isbn ?? book.metadata.isbn,
            synopsis: candidate.synopsis ?? book.metadata.synopsis,
            pageCountEstimate: candidate.pageCount ?? book.metadata.pageCountEstimate,
            coverAssetID: book.metadata.coverAssetID,
            source: source,
            fetchedAt: Date())
        store.updateMetadata(updated, for: book)

        if let coverURL = candidate.coverURL {
            Task { [weak store] in
                guard let store else { return }
                guard let (data, _) = try? await URLSession.shared.data(from: coverURL) else { return }
                let assetID = await MainActor.run { store.saveCoverData(data) }
                guard let assetID else { return }
                await MainActor.run {
                    if let refreshed = store.books.first(where: { $0.id == book.id }) {
                        var m = refreshed.metadata
                        m.coverAssetID = assetID
                        store.updateMetadata(m, for: refreshed)
                    }
                }
            }
        }
    }
}
