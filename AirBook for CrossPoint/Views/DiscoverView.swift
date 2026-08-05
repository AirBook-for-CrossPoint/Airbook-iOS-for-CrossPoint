import SwiftUI

// MARK: - Discover View
//
// Sheet for searching Z-Library and downloading books straight into the
// local AirBook library. Follows the same paperBackground / paperInk /
// paperRule design tokens used everywhere else.
//
// Three states share one screen:
//   * not logged in            → login fields
//   * logged in, no results    → empty / hint state
//   * logged in, with results  → search bar + chips + scrollable list
//
// Tapping a result opens DiscoverBookSheet, which lazily fetches the book
// detail page, shows a longer description, and exposes the Download button.

struct DiscoverView: View {
    @Environment(ZLibService.self) private var service
    @Environment(BookStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var queryText: String = ""
    @State private var ext: ZLibExtension = .epub
    @State private var language: ZLibLanguage = .any
    @State private var results: [ZLibSearchResult] = []
    @State private var loading: Bool = false
    @State private var errorMessage: String?
    @State private var selectedBook: ZLibSearchResult?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.paperBackground.ignoresSafeArea()

                if service.isLoggedIn {
                    loggedInBody
                } else {
                    DiscoverLoginPanel()
                        .environment(service)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Discover")
                        .font(.system(.subheadline, design: .serif).weight(.bold))
                        .foregroundStyle(Color.paperInk)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(Color.paperInk)
                }
                if service.isLoggedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Refresh quota") {
                                Task { try? await service.fetchLimits() }
                            }
                            Button("Log out", role: .destructive) {
                                service.logout()
                                results = []
                            }
                        } label: {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 14, weight: .light))
                                .foregroundStyle(Color.paperInk)
                        }
                    }
                }
            }
            .toolbarBackground(Color.paperBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $selectedBook) { book in
            DiscoverBookSheet(seed: book)
                .environment(service)
                .environment(store)
        }
        .onAppear {
            if service.isLoggedIn && service.limits == nil {
                Task { try? await service.fetchLimits() }
            }
        }
    }

    // MARK: Logged-in body

    @ViewBuilder
    private var loggedInBody: some View {
        VStack(spacing: 0) {
            searchBar
            filterStrip
            if let limits = service.limits {
                quotaBar(limits)
            }
            Rectangle().fill(Color.paperRule.opacity(0.35)).frame(height: 0.5)

            if loading {
                loadingBody
            } else if let errorMessage {
                errorBody(errorMessage)
            } else if results.isEmpty {
                emptyBody
            } else {
                resultList
            }

            // Persistent background-download status. Visible whenever the
            // service is mid-download or has a terminal result that
            // hasn't been acknowledged yet — so dismissing the book
            // detail sheet doesn't lose visibility into what's happening.
            backgroundDownloadFooter
        }
    }

    @ViewBuilder
    private var backgroundDownloadFooter: some View {
        switch service.activeDownload {
        case .downloading(let book, let done, let total):
            backgroundFooterRow(
                book: book,
                title: total > 0 ? "Downloading · \(Int((Double(done) / Double(total)) * 100))%"
                                 : "Downloading…",
                tint: Color.paperInk,
                fraction: total > 0 ? Double(done) / Double(total) : nil)
        case .importing(let book):
            backgroundFooterRow(
                book: book,
                title: "Importing into library…",
                tint: Color.paperInk,
                fraction: nil)
        case .completed(let book, _):
            backgroundFooterRow(
                book: book,
                title: "Saved to library",
                tint: Color.paperInk,
                fraction: 1,
                trailing: dismissButton())
        case .failed(let book, let msg):
            backgroundFooterRow(
                book: book,
                title: "Download failed: \(msg)",
                tint: Color.paperError,
                fraction: nil,
                trailing: dismissButton())
        case .idle:
            EmptyView()
        }
    }

    private func backgroundFooterRow(book: ZLibSearchResult,
                                      title: String,
                                      tint: Color,
                                      fraction: Double?,
                                      trailing: (some View)? = Optional<EmptyView>.none) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.paperInk.opacity(0.12)).frame(height: 0.5)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .foregroundStyle(tint)
                    Text(book.title)
                        .font(.system(.footnote, design: .serif))
                        .foregroundStyle(Color.paperInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let trailing {
                    trailing
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.paperRule.opacity(0.18))
                        Rectangle().fill(tint)
                            .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
                            .animation(.linear(duration: 0.4), value: fraction)
                    }
                }
                .frame(height: 2)
            }
        }
        .background(Color.paperBackground)
    }

    private func dismissButton() -> some View {
        Button {
            service.acknowledgeDownload()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(Color.paperRule)
                .frame(width: 24, height: 24)
        }
    }

    // MARK: Search controls

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(Color.paperRule)
                TextField("Search title, author, ISBN", text: $queryText)
                    .font(.system(.footnote, design: .serif))
                    .foregroundStyle(Color.paperInk)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(runSearch)
                if !queryText.isEmpty {
                    Button {
                        queryText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .light))
                            .foregroundStyle(Color.paperRule)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(Rectangle().stroke(Color.paperRule.opacity(0.4), lineWidth: 0.6))

            Button {
                runSearch()
            } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.paperBackground)
                    .frame(width: 30, height: 30)
                    .background(Color.paperInk)
            }
            .disabled(queryText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(ZLibExtension.allCases) { e in
                        Button(e.rawValue) { ext = e }
                    }
                } label: {
                    chipLabel(text: ext.rawValue, selected: ext != .any)
                }
                Menu {
                    ForEach(ZLibLanguage.allCases) { l in
                        Button(l.label) { language = l }
                    }
                } label: {
                    chipLabel(text: language.label, selected: language != .any)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 6)
    }

    private func chipLabel(text: String, selected: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(.caption2, design: .monospaced))
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .medium))
        }
        .foregroundStyle(selected ? Color.paperBackground : Color.paperInk)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(selected ? Color.paperInk : Color.paperBackground)
        .overlay(Rectangle().stroke(Color.paperInk, lineWidth: 0.6))
    }

    private func quotaBar(_ limits: ZLibLimits) -> some View {
        HStack(spacing: 8) {
            Text("DAILY")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.paperRule)
            Text("\(limits.dailyUsed)/\(limits.dailyAllowed)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.paperInk)
            Spacer()
            if !limits.resetIn.isEmpty {
                Text("RESETS IN \(limits.resetIn.uppercased())")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    // MARK: List / states

    private var loadingBody: some View {
        VStack {
            Spacer()
            ProgressView().tint(Color.paperInk)
            Text("Searching z-lib.sk…")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.paperRule)
                .padding(.top, 10)
            Spacer()
        }
    }

    private func errorBody(_ message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 26, weight: .ultraLight))
                .foregroundStyle(Color.paperRule)
            Text("Search failed")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(Color.paperInk)
            Text(message)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.paperRule)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") { runSearch() }
                .font(.system(.subheadline, design: .serif).weight(.bold))
                .foregroundStyle(Color.paperInk)
                .padding(.top, 8)
            Spacer()
        }
    }

    private var emptyBody: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(Color.paperRule.opacity(0.7))
            Text("Search the Z-Library catalog")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(Color.paperInk)
            Text("Type a title, author, or ISBN — pick a format, then tap a result to download it into your AirBook library.")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.paperRule)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(results) { book in
                    VStack(spacing: 0) {
                        Button {
                            selectedBook = book
                        } label: {
                            DiscoverResultRow(book: book)
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(Color.paperRule.opacity(0.2))
                            .frame(height: 0.5)
                            .padding(.leading, 88)
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: Actions

    private func runSearch() {
        let q = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        loading = true
        errorMessage = nil
        Task {
            do {
                let r = try await service.search(query: q, page: 1,
                                                 ext: ext, language: language)
                await MainActor.run {
                    results = r
                    loading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    loading = false
                }
            }
        }
    }
}

// MARK: - Result row

private struct DiscoverResultRow: View {
    let book: ZLibSearchResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cover
                .frame(width: 56, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.paperInk.opacity(0.14), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.system(.subheadline, design: .serif).weight(.bold))
                    .foregroundStyle(Color.paperInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !book.authors.isEmpty {
                    Text(book.authors.joined(separator: ", "))
                        .font(.system(.caption, design: .serif))
                        .foregroundStyle(Color.paperRule)
                        .lineLimit(1)
                }
                facts
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var cover: some View {
        ZLibCoverImage(url: book.coverURL)
    }

    private var facts: some View {
        HStack(spacing: 6) {
            if !book.ext.isEmpty {
                Text(book.ext.uppercased())
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color.paperInk)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Rectangle().stroke(Color.paperInk, lineWidth: 0.5))
            }
            if !book.year.isEmpty {
                Text(book.year)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
            }
            if !book.filesize.isEmpty {
                Text("· \(book.filesize)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("Z-LIB")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.paperRule.opacity(0.7))
        }
    }
}

// MARK: - Login panel

private struct DiscoverLoginPanel: View {
    @Environment(ZLibService.self) private var service

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var remember: Bool = true
    @State private var working: Bool = false
    @State private var errorMessage: String?
    @State private var showingNetworkDebug: Bool = false
    @State private var domainDraft: String = ""
    @State private var selectedDNSMode: ZLibDNSMode = .system
    @State private var diagnosticReport: ZLibDiagnosticReport?
    @State private var diagnosticRunning: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                VStack(alignment: .leading, spacing: 12) {
                    field(label: "Email", text: $email,
                          contentType: .username, keyboard: .emailAddress)
                    secureField(label: "Password", text: $password)
                }

                Toggle(isOn: $remember) {
                    Text("Remember me on this device")
                        .font(.system(.footnote, design: .serif))
                        .foregroundStyle(Color.paperInk)
                }
                .tint(Color.paperInk)

                networkDebugPanel

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.paperError)
                        .padding(.vertical, 4)
                }

                Button {
                    submit()
                } label: {
                    HStack {
                        if working { ProgressView().tint(Color.paperBackground) }
                        Text(working ? "Signing in…" : "Sign in to Z-Library")
                            .font(.system(.headline, design: .serif))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.paperInk)
                    .foregroundStyle(Color.paperBackground)
                }
                .disabled(working || email.isEmpty || password.isEmpty)

                Text("Stored on this device only. Password kept in the iOS keychain. Domain: z-lib.sk.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .onAppear {
            if email.isEmpty { email = service.savedEmail }
            if password.isEmpty, let stored = service.savedPassword { password = stored }
            if domainDraft.isEmpty { domainDraft = service.domain }
            selectedDNSMode = service.dnsMode
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Z-Library Sign-In")
                .font(.system(.title2, design: .serif).weight(.bold))
                .foregroundStyle(Color.paperInk)
            Rectangle().fill(Color.paperInk).frame(height: 1)
            Text("Authenticate to search and download books. The session cookie stays in this app's storage; no third parties are involved.")
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(Color.paperRule)
                .padding(.top, 6)
        }
        .padding(.top, 8)
    }

    private func field(label: String, text: Binding<String>,
                       contentType: UITextContentType, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.paperRule)
            TextField(label, text: text)
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(Color.paperInk)
                .textContentType(contentType)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.vertical, 8)
                .overlay(Rectangle().fill(Color.paperRule.opacity(0.4))
                    .frame(height: 0.6), alignment: .bottom)
        }
    }

    private func secureField(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.paperRule)
            SecureField(label, text: text)
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(Color.paperInk)
                .textContentType(.password)
                .padding(.vertical, 8)
                .overlay(Rectangle().fill(Color.paperRule.opacity(0.4))
                    .frame(height: 0.6), alignment: .bottom)
        }
    }

    private var networkDebugPanel: some View {
        DisclosureGroup(isExpanded: $showingNetworkDebug) {
            VStack(alignment: .leading, spacing: 12) {
                field(label: "Endpoint", text: $domainDraft,
                      contentType: .URL, keyboard: .URL)

                VStack(alignment: .leading, spacing: 6) {
                    Text("DNS MODE")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.paperRule)
                    Picker("DNS mode", selection: $selectedDNSMode) {
                        ForEach(ZLibDNSMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedDNSMode) { newValue in
                        service.setDNSMode(newValue)
                        diagnosticReport = nil
                    }
                    Text(selectedDNSMode.detail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.paperRule)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    runNetworkDebug()
                } label: {
                    HStack(spacing: 8) {
                        if diagnosticRunning { ProgressView().scaleEffect(0.7).tint(Color.paperInk) }
                        Image(systemName: "network")
                            .font(.system(size: 11, weight: .light))
                        Text(diagnosticRunning ? "Testing network…" : "Run network debug")
                    }
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(Color.paperInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .overlay(Rectangle().stroke(Color.paperInk, lineWidth: 0.6))
                }
                .disabled(diagnosticRunning)

                if let diagnosticReport {
                    diagnosticReportView(diagnosticReport)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .light))
                Text("Network debug")
                    .font(.system(.caption, design: .monospaced).weight(.medium))
            }
            .foregroundStyle(Color.paperInk)
        }
        .tint(Color.paperInk)
        .padding(.vertical, 4)
    }

    private func diagnosticReportView(_ report: ZLibDiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Last check · \(report.generatedAt.formatted(date: .omitted, time: .standard))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.paperRule)
            ForEach(report.steps) { step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: step.status.symbolName)
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(step.status == .failed ? Color.paperError : Color.paperInk)
                        .frame(width: 14, height: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.system(.caption2, design: .monospaced).weight(.bold))
                            .foregroundStyle(Color.paperInk)
                        Text(step.detail)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(step.status == .failed ? Color.paperError : Color.paperRule)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func submit() {
        errorMessage = nil
        applyNetworkDebugSettings()
        working = true
        Task {
            do {
                try await service.login(email: email, password: password, remember: remember)
                await MainActor.run { working = false }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    working = false
                }
            }
        }
    }

    private func runNetworkDebug() {
        applyNetworkDebugSettings()
        diagnosticRunning = true
        diagnosticReport = nil
        Task {
            let report = await service.runConnectivityDiagnostic()
            await MainActor.run {
                diagnosticReport = report
                diagnosticRunning = false
            }
        }
    }

    private func applyNetworkDebugSettings() {
        service.setDomain(domainDraft)
        domainDraft = service.domain
        service.setDNSMode(selectedDNSMode)
    }
}

// MARK: - Book detail sheet (download)

struct DiscoverBookSheet: View {
    let seed: ZLibSearchResult

    @Environment(ZLibService.self) private var service
    @Environment(BookStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var detail: ZLibBookDetail?
    @State private var loading: Bool = true
    @State private var errorMessage: String?

    // Whether the sheet should show progress for THIS book specifically.
    // True if service.activeDownload concerns `seed`. Lets the user open
    // a different book detail without seeing the wrong progress, and lets
    // them re-open the SAME book mid-download to see live progress.
    private var isThisDownloadActive: Bool {
        guard let book = service.activeDownload.inProgressBook else { return false }
        return book.id == seed.id
    }
    private var thisDownloadResult: ZLibDownloadStatus? {
        switch service.activeDownload {
        case .completed(let b, _) where b.id == seed.id, .failed(let b, _) where b.id == seed.id:
            return service.activeDownload
        default:
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.paperBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        coverSection
                        titleSection
                        factsSection
                        if loading { loadingPlaceholder }
                        if let message = errorMessage { errorBox(message) }
                        if let detail, let synopsis = detail.description, !synopsis.isEmpty {
                            synopsisSection(synopsis)
                        }
                        downloadSection
                        if let result = thisDownloadResult,
                           case .completed(_, let id) = result,
                           let book = store.books.first(where: { $0.id == id }) {
                            successBlock(book)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Book")
                        .font(.system(.subheadline, design: .serif).weight(.bold))
                        .foregroundStyle(Color.paperInk)
                }
                ToolbarItem(placement: .topBarLeading) {
                    // Close is always enabled — the download moved into
                    // ZLibService so dismissing the sheet just hides the
                    // UI. The download keeps running and surfaces on
                    // re-entry (or on the global Discover view footer).
                    Button("Close") { dismiss() }
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(Color.paperInk)
                }
            }
            .toolbarBackground(Color.paperBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear(perform: loadDetail)
    }

    // MARK: Sections

    private var coverSection: some View {
        ZLibCoverImage(url: detail?.coverURL ?? seed.coverURL)
            .aspectRatio(2.0/3.0, contentMode: .fit)
            .frame(maxWidth: 150)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.paperInk.opacity(0.14), lineWidth: 0.7))
            .padding(.top, 4)
    }

    private var titleSection: some View {
        VStack(spacing: 6) {
            Text(detail?.title ?? seed.title)
                .font(.system(.title3, design: .serif).weight(.bold))
                .foregroundStyle(Color.paperInk)
                .multilineTextAlignment(.center)
            let authors = !(detail?.authors ?? []).isEmpty ? (detail?.authors ?? []) : seed.authors
            if !authors.isEmpty {
                Text(authors.joined(separator: ", "))
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(Color.paperRule)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var factsSection: some View {
        VStack(spacing: 8) {
            paperRule
            VStack(spacing: 4) {
                if let v = detail?.publisher ?? (seed.publisher.isEmpty ? nil : seed.publisher) {
                    factRow("Publisher", v)
                }
                let yr = detail?.year ?? (seed.year.isEmpty ? nil : seed.year)
                if let v = yr, !v.isEmpty { factRow("Year", v) }
                let lang = detail?.language ?? (seed.language.isEmpty ? nil : seed.language)
                if let v = lang, !v.isEmpty { factRow("Language", v) }
                let ext = detail?.ext ?? (seed.ext.isEmpty ? nil : seed.ext)
                if let v = ext, !v.isEmpty { factRow("Format", v.uppercased()) }
                let size = detail?.size ?? (seed.filesize.isEmpty ? nil : seed.filesize)
                if let v = size, !v.isEmpty { factRow("Size", v) }
                let isbn = detail?.isbn ?? (seed.isbn.isEmpty ? nil : seed.isbn)
                if let v = isbn, !v.isEmpty { factRow("ISBN", v) }
                if let categories = detail?.categories, !categories.isEmpty {
                    factRow("Categories", categories)
                }
            }
            paperRule
        }
    }

    private func synopsisSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SYNOPSIS")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.paperRule)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(text)
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(Color.paperInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var downloadSection: some View {
        let canImport = supportedByLibrary(detail?.ext ?? seed.ext)
        let hasLink = detail?.downloadURL != nil

        if isThisDownloadActive {
            // Live progress for this book. Reads straight from
            // service.activeDownload so the bar keeps moving even if the
            // sheet was just re-opened mid-download.
            switch service.activeDownload {
            case .downloading(_, let done, let total):
                let p = total > 0 ? Double(done) / Double(total) : 0
                VStack(spacing: 8) {
                    ProgressView(value: max(0, min(1, p)))
                        .tint(Color.paperInk)
                    HStack {
                        Text(byteProgressLabel(done: done, total: total))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Color.paperRule)
                        Spacer()
                        Text("\(Int(p * 100))%")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Color.paperInk)
                    }
                }
                .padding(.vertical, 4)
            case .importing:
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6).tint(Color.paperInk)
                    Text("Importing into library…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.paperInk)
                }
                .padding(.vertical, 6)
            default:
                EmptyView()
            }
        } else if thisDownloadResult == nil {
            // No active or completed download for this book → show the
            // start button. If a DIFFERENT book is currently downloading,
            // gate the button so we don't queue parallel downloads.
            let blockedByOther = service.activeDownload.isActive

            Button {
                startDownload()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14, weight: .medium))
                    Text(downloadButtonLabel(hasLink: hasLink, canImport: canImport))
                        .font(.system(.headline, design: .serif))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canImport && hasLink && !blockedByOther ? Color.paperInk : Color.paperRule.opacity(0.3))
                .foregroundStyle(canImport && hasLink && !blockedByOther ? Color.paperBackground : Color.paperInk.opacity(0.5))
            }
            .disabled(!canImport || !hasLink || loading || blockedByOther)
            .padding(.top, 8)

            if blockedByOther, let other = service.activeDownload.inProgressBook {
                Text("Already downloading \"\(other.title)\" in the background.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else if !canImport, let ext = (detail?.ext ?? seed.ext).nonEmpty {
                Text("Format .\(ext.lowercased()) isn't supported by your CrossPoint yet. EPUB, TXT, BMP, XTC, XTCH only.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.paperError)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else if !hasLink && !loading {
                Text("No download link visible on this book yet — your daily quota may be spent, or the file is restricted.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }

        if case .failed(_, let message) = thisDownloadResult ?? .idle {
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.paperError)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
    }

    private func byteProgressLabel(done: Int64, total: Int64) -> String {
        if total > 0 {
            let d = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
            let t = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return "\(d) / \(t)"
        }
        return ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
    }

    private func successBlock(_ book: Book) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Color.paperInk)
            Text("Added to your library")
                .font(.system(.subheadline, design: .serif).weight(.bold))
                .foregroundStyle(Color.paperInk)
            Text(book.filename)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.paperRule)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Button("Done") { dismiss() }
                .font(.system(.subheadline, design: .serif).weight(.bold))
                .foregroundStyle(Color.paperInk)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .overlay(Rectangle().stroke(Color.paperInk.opacity(0.2), lineWidth: 0.5))
    }

    private var loadingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView().tint(Color.paperRule)
            Text("Loading book details…")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.paperRule)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func errorBox(_ message: String) -> some View {
        Text(message)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Color.paperError)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    // MARK: Helpers

    private func loadDetail() {
        guard !seed.detailPath.isEmpty else {
            loading = false
            return
        }
        loading = true
        errorMessage = nil
        Task {
            do {
                let d = try await service.fetchBookDetail(detailPath: seed.detailPath)
                await MainActor.run {
                    detail = d
                    loading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    loading = false
                }
            }
        }
    }

    private func startDownload() {
        guard let detail else { return }
        // Delegate to the service so the download survives the sheet
        // being dismissed mid-flight. The view just observes
        // service.activeDownload from here on.
        service.startBackgroundDownload(seed: seed, detail: detail, into: store)
    }

    private func downloadButtonLabel(hasLink: Bool, canImport: Bool) -> String {
        if !canImport { return "Format not supported" }
        if loading { return "Preparing…" }
        if !hasLink { return "No download link" }
        return "Download to Library"
    }

    private func supportedByLibrary(_ ext: String) -> Bool {
        let lower = ext.lowercased()
        return BookStore.supportedExtensions.contains(lower)
    }

    private var paperRule: some View {
        Rectangle().fill(Color.paperRule.opacity(0.35)).frame(height: 0.5)
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.paperRule)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(Color.paperInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - tiny helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Authenticated cover image
//
// AsyncImage uses URLSession.shared with the default iOS User-Agent and no
// Referer. Z-Library's CDN frequently 403s those requests. ZLibCoverImage
// loads via the service's session so the browser UA, cookies, and Referer
// header reach the CDN. Results are kept in a tiny in-memory cache so
// scrolling back and forth doesn't refetch.

final class ZLibImageCache {
    static let shared = ZLibImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private init() { cache.countLimit = 256 }
    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func set(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

struct ZLibCoverImage: View {
    let url: URL?
    @Environment(ZLibService.self) private var service
    @State private var image: UIImage?
    @State private var failed: Bool = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if failed || url == nil {
                Rectangle().fill(Color.paperRule.opacity(0.18))
                    .overlay(
                        Image(systemName: "book.closed")
                            .font(.system(size: 18, weight: .ultraLight))
                            .foregroundStyle(Color.paperRule.opacity(0.5))
                    )
            } else {
                Rectangle().fill(Color.paperRule.opacity(0.12))
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(Color.paperRule)
                    )
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        if let cached = ZLibImageCache.shared.image(for: url) {
            image = cached
            return
        }
        do {
            let data = try await service.fetchImageData(url)
            if let img = UIImage(data: data) {
                ZLibImageCache.shared.set(img, for: url)
                image = img
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}
