import SwiftUI

// MARK: - Annotations browser
//
// Cross-book viewer for highlights synced from the CrossPoint reader.
// Pulls from ReadingStateStore for every book in BookStore, flattens
// them into a single chronological list, and lets the user filter by
// color, by book, and by recency.

struct AnnotationsView: View {
    @Environment(BookStore.self) private var store
    @Environment(ReadingStateStore.self) private var readingStateStore
    @Environment(\.dismiss) private var dismiss

    @State private var colorFilter: HighlightColor?  // nil = all
    @State private var bookFilter: UUID?             // nil = all
    @State private var dateFilter: DateFilter = .all

    enum DateFilter: String, CaseIterable, Identifiable {
        case all = "All time"
        case last7 = "Last 7 days"
        case last30 = "Last 30 days"
        case last90 = "Last 90 days"
        var id: String { rawValue }
        var cutoff: Date? {
            switch self {
            case .all: return nil
            case .last7:  return Calendar.current.date(byAdding: .day, value: -7, to: Date())
            case .last30: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
            case .last90: return Calendar.current.date(byAdding: .day, value: -90, to: Date())
            }
        }
    }

    var body: some View {
        // Observation tripwire: AnnotationsView reads through `state(for:)`
        // which doesn't touch the store's `revision` counter; we touch
        // it explicitly so any highlight mutation re-renders us.
        _ = readingStateStore.revision

        return NavigationStack {
            ZStack {
                Color.paperBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    filterStrip
                    Rectangle().fill(Color.paperRule.opacity(0.35)).frame(height: 0.5)
                    list
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Highlights")
                        .font(.system(.subheadline, design: .serif).weight(.bold))
                        .foregroundStyle(Color.paperInk)
                }
                ToolbarItem(placement: .topBarLeading) {
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

    // MARK: Filter strip

    private var filterStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("COLOR")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
                    .frame(width: 56, alignment: .leading)
                colorChip(label: "All", color: nil)
                ForEach(HighlightColor.allCases, id: \.self) { c in
                    colorChip(label: nil, color: c)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Text("WHEN")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
                    .frame(width: 56, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(DateFilter.allCases) { f in
                            chip(label: f.rawValue, isOn: dateFilter == f) {
                                dateFilter = f
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text("BOOK")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
                    .frame(width: 56, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip(label: "All", isOn: bookFilter == nil) { bookFilter = nil }
                        ForEach(booksWithHighlights) { book in
                            chip(label: book.displayTitle, isOn: bookFilter == book.id) {
                                bookFilter = book.id
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func colorChip(label: String?, color: HighlightColor?) -> some View {
        let isOn = colorFilter == color
        return Button {
            colorFilter = isOn ? nil : color
        } label: {
            HStack(spacing: 4) {
                if let c = color {
                    Rectangle().fill(swatch(c)).frame(width: 12, height: 12)
                }
                if let label {
                    Text(label)
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(isOn ? Color.paperBackground : Color.paperInk)
            .background(isOn ? Color.paperInk : Color.clear)
            .overlay(Rectangle().stroke(Color.paperInk, lineWidth: isOn ? 0 : 0.5))
        }
    }

    private func chip(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .foregroundStyle(isOn ? Color.paperBackground : Color.paperInk)
                .background(isOn ? Color.paperInk : Color.clear)
                .overlay(Rectangle().stroke(Color.paperInk, lineWidth: isOn ? 0 : 0.5))
        }
    }

    // MARK: List

    private var list: some View {
        Group {
            let items = filteredHighlights
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items, id: \.highlight.id) { item in
                            VStack(spacing: 0) {
                                row(item)
                                Rectangle().fill(Color.paperRule.opacity(0.2))
                                    .frame(height: 0.5)
                                    .padding(.leading, 24)
                            }
                        }
                    }
                    .padding(.bottom, 30)
                }
            }
        }
    }

    private func row(_ item: AnnotatedHighlight) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(swatch(item.highlight.colorTag))
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                if !item.highlight.snippet.isEmpty {
                    Text(item.highlight.snippet)
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(Color.paperInk)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                }
                if let note = item.highlight.note, !note.isEmpty {
                    Text("Note: \(note)")
                        .font(.system(.caption, design: .serif))
                        .foregroundStyle(Color.paperRule)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(item.bookTitle)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.paperInk)
                        .lineLimit(1)
                    Text("·")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.paperRule)
                    Text(item.relativeDate)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.paperRule)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "highlighter")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(Color.paperRule)
            Text(allHighlights.isEmpty
                    ? "No highlights yet. Make some on your CrossPoint, then sync."
                    : "No highlights match these filters.")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(Color.paperRule)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    // MARK: Data shaping

    /// Per-row item wrapping a HighlightRecord with the book title cached.
    /// Keeps the SwiftUI row pure (no per-render store lookups).
    private struct AnnotatedHighlight {
        let highlight: HighlightRecord
        let bookID: UUID
        let bookTitle: String
        let updatedAt: Date
        let relativeDate: String
    }

    private var booksWithHighlights: [Book] {
        // Stable order by book title — chip strip becomes a scannable list.
        let ids = Set(allHighlights.map(\.bookID))
        return store.books
            .filter { ids.contains($0.id) }
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    private var allHighlights: [AnnotatedHighlight] {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        var out: [AnnotatedHighlight] = []
        for book in store.books {
            let state = readingStateStore.state(for: book.id)
            for hl in state.highlights {
                out.append(AnnotatedHighlight(
                    highlight: hl,
                    bookID: book.id,
                    bookTitle: book.displayTitle,
                    updatedAt: hl.updatedAt,
                    relativeDate: formatter.localizedString(for: hl.updatedAt, relativeTo: Date())))
            }
        }
        // Newest first.
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var filteredHighlights: [AnnotatedHighlight] {
        var items = allHighlights
        if let c = colorFilter {
            items = items.filter { $0.highlight.colorTag == c }
        }
        if let b = bookFilter {
            items = items.filter { $0.bookID == b }
        }
        if let cutoff = dateFilter.cutoff {
            items = items.filter { $0.updatedAt >= cutoff }
        }
        return items
    }

    private func swatch(_ c: HighlightColor) -> Color {
        switch c {
        case .yellow: return Color(red: 0.85, green: 0.75, blue: 0.32)
        case .blue:   return Color(red: 0.32, green: 0.55, blue: 0.78)
        case .pink:   return Color(red: 0.80, green: 0.45, blue: 0.62)
        case .green:  return Color(red: 0.42, green: 0.65, blue: 0.42)
        }
    }
}
