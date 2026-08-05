import Foundation
import CryptoKit
import Network
import Security

// MARK: - Models

struct ZLibSearchResult: Identifiable, Equatable {
    let id: String
    let title: String
    let authors: [String]
    let publisher: String
    let year: String
    let language: String
    let ext: String
    let filesize: String
    let rating: String
    let coverURL: URL?
    /// Relative path on z-lib.sk, e.g. "/book/12345/abcdef/title.html".
    let detailPath: String
    let isbn: String
}

struct ZLibBookDetail: Equatable {
    var id: String
    var title: String
    var authors: [String]
    var coverURL: URL?
    var description: String?
    var year: String?
    var publisher: String?
    var language: String?
    var ext: String?
    var size: String?
    var isbn: String?
    var categories: String?
    /// Absolute URL to /dl/<token> or /file/<token>. nil → no permission /
    /// download link gated behind something else.
    var downloadURL: URL?
}

struct ZLibLimits: Equatable {
    var dailyUsed: Int
    var dailyAllowed: Int
    var resetIn: String
    var remaining: Int { max(0, dailyAllowed - dailyUsed) }
}

enum ZLibExtension: String, CaseIterable, Identifiable {
    case any = "ANY"
    case epub = "EPUB"
    case pdf = "PDF"
    case mobi = "MOBI"
    case azw3 = "AZW3"
    case fb2 = "FB2"
    case txt = "TXT"
    case rtf = "RTF"
    case djvu = "DJVU"
    var id: String { rawValue }
    var queryValue: String? { self == .any ? nil : rawValue }
}

enum ZLibLanguage: String, CaseIterable, Identifiable {
    case any
    case english, italian, french, german, spanish
    case russian, chinese, japanese, korean, portuguese
    var id: String { rawValue }
    var label: String { self == .any ? "ANY LANG" : rawValue.uppercased() }
    var queryValue: String? { self == .any ? nil : rawValue }
}

enum ZLibError: LocalizedError {
    case notLoggedIn
    case loginFailed(String)
    case sessionExpired
    case parseFailed
    case network(String)
    case noDownloadLink
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:        return "Not logged in to Z-Library."
        case .loginFailed(let m): return "Login failed: \(m)"
        case .sessionExpired:     return "Session expired. Log in again."
        case .parseFailed:        return "Could not parse the response (site layout may have changed)."
        case .network(let m):     return "Network error: \(m)"
        case .noDownloadLink:     return "No download link found on this book."
        case .downloadFailed(let m): return "Download failed: \(m)"
        }
    }
}

enum ZLibDNSMode: String, CaseIterable, Identifiable {
    case system
    case cloudflareHTTPS

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .cloudflareHTTPS: return "Encrypted"
        }
    }

    var detail: String {
        switch self {
        case .system:
            return "Uses the iPhone, Wi-Fi, VPN, or carrier DNS resolver."
        case .cloudflareHTTPS:
            return "Asks iOS to resolve this app's hostnames through Cloudflare DNS-over-HTTPS."
        }
    }
}

enum ZLibDiagnosticStatus: String, Equatable {
    case info
    case ok
    case warning
    case failed

    var symbolName: String {
        switch self {
        case .info: return "info.circle"
        case .ok: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .failed: return "xmark.circle"
        }
    }
}

struct ZLibDiagnosticStep: Identifiable, Equatable {
    let id = UUID()
    let status: ZLibDiagnosticStatus
    let title: String
    let detail: String
}

struct ZLibDiagnosticReport: Equatable {
    let generatedAt: Date
    let domain: String
    let dnsMode: ZLibDNSMode
    let steps: [ZLibDiagnosticStep]
}

// MARK: - Tiny Keychain helper
//
// Stores Z-Library credentials so the user doesn't re-type them every launch.
// Personal-use app: a single account namespace ("zlib.password") is enough.

private enum ZLibKeychain {
    static let service = "io.airbook.zlib"

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        _ = SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Backgroundable download status

enum ZLibDownloadStatus: Equatable {
    case idle
    case downloading(book: ZLibSearchResult, receivedBytes: Int64, totalBytes: Int64)
    case importing(book: ZLibSearchResult)
    case completed(book: ZLibSearchResult, importedBookID: UUID)
    case failed(book: ZLibSearchResult, message: String)

    var isActive: Bool {
        switch self {
        case .downloading, .importing: return true
        default: return false
        }
    }

    var inProgressBook: ZLibSearchResult? {
        switch self {
        case .downloading(let b, _, _), .importing(let b): return b
        default: return nil
        }
    }
}

// MARK: - ZLibService
//
// Personal-use Z-Library client implementing the subset of the heartleo/zlib
// Go library described in docs/zlib-api-technical-reference.md:
//   * POST /rpc.php  → login (form-urlencoded + gg_json_mode=1)
//   * GET  /s/<q>    → search (HTML, z-bookcard custom-element parsing)
//   * GET  /book/... → book detail
//   * GET  /dl/...   → download
//   * GET  /users/downloads → daily limits
//
// Cookies persist in HTTPCookieStorage.shared (the iOS cookie store survives
// app relaunches when cookies have an expiration date — z-lib does). Cloudflare
// SHA-1 PoW is solved in pure Swift using CryptoKit's Insecure.SHA1 when a
// challenge page is detected (small HTML body + magic regex).

@Observable
@MainActor
final class ZLibService {

    // MARK: - Public observable state

    var domain: String = "https://z-lib.sk"
    var dnsMode: ZLibDNSMode = .system
    var isLoggedIn: Bool = false
    var savedEmail: String = ""
    var limits: ZLibLimits?
    /// Backgroundable download status. State lives in the service so a
    /// download survives the user dismissing DiscoverBookSheet — the
    /// sheet just observes this property and re-acquires the UI on
    /// re-open. `idle` means free to start a new one.
    var activeDownload: ZLibDownloadStatus = .idle

    // MARK: - Private

    @ObservationIgnored private var session: URLSession
    @ObservationIgnored private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let emailKey = "zlib.email"
    @ObservationIgnored private let domainKey = "zlib.domain"
    @ObservationIgnored private let dnsModeKey = "zlib.dnsMode"
    @ObservationIgnored private let passwordAccount = "zlib.password"

    // MARK: - Init

    init() {
        self.session = Self.makeSession()
        if let savedDomain = defaults.string(forKey: domainKey) {
            domain = Self.normalizedDomain(savedDomain)
        }
        if let rawMode = defaults.string(forKey: dnsModeKey),
           let savedMode = ZLibDNSMode(rawValue: rawMode) {
            dnsMode = savedMode
        }
        Self.applyDNSPolicy(dnsMode)

        if let saved = defaults.string(forKey: emailKey) {
            savedEmail = saved
        }
        refreshLoginState()
    }

    private static func makeSession() -> URLSession {
        let config = makeSessionConfiguration()
        return URLSession(configuration: config)
    }

    private static func makeSessionConfiguration(requestTimeout: TimeInterval = 60,
                                                 resourceTimeout: TimeInterval = 180) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        // Set User-Agent at session level so EVERY request (including cover
        // images via fetchImageData) looks browser-like. Without it z-lib's
        // CDN frequently 403s thumbnail requests.
        config.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Sec-Fetch-Dest": "document",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Site": "none",
            "Sec-Fetch-User": "?1",
            "Upgrade-Insecure-Requests": "1"
        ]
        return config
    }

    private static func applyDNSPolicy(_ mode: ZLibDNSMode) {
        switch mode {
        case .system:
            NWParameters.PrivacyContext.default.requireEncryptedNameResolution(false, fallbackResolver: nil)
        case .cloudflareHTTPS:
            guard let dohURL = URL(string: "https://cloudflare-dns.com/dns-query") else { return }
            let addresses: [NWEndpoint] = [
                .hostPort(host: "1.1.1.1", port: 443),
                .hostPort(host: "1.0.0.1", port: 443)
            ]
            NWParameters.PrivacyContext.default.requireEncryptedNameResolution(
                true,
                fallbackResolver: .https(dohURL, serverAddresses: addresses))
        }
    }

    func setDomain(_ rawValue: String) {
        let normalized = Self.normalizedDomain(rawValue)
        guard !normalized.isEmpty, normalized != domain else { return }
        domain = normalized
        defaults.set(normalized, forKey: domainKey)
        logout()
        refreshLoginState()
    }

    func setDNSMode(_ mode: ZLibDNSMode) {
        guard mode != dnsMode else { return }
        dnsMode = mode
        defaults.set(mode.rawValue, forKey: dnsModeKey)
        Self.applyDNSPolicy(mode)
        session.invalidateAndCancel()
        session = Self.makeSession()
    }

    private func prepareNetworkPolicy() {
        Self.applyDNSPolicy(dnsMode)
    }

    private static func normalizedDomain(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.isEmpty { return "" }
        if !value.lowercased().hasPrefix("http://") &&
            !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        return value
    }

    // MARK: - Credential persistence

    var savedPassword: String? { ZLibKeychain.get(account: passwordAccount) }

    func persistCredentials(email: String, password: String) {
        defaults.set(email, forKey: emailKey)
        savedEmail = email
        ZLibKeychain.set(password, account: passwordAccount)
    }

    func clearStoredCredentials() {
        defaults.removeObject(forKey: emailKey)
        savedEmail = ""
        ZLibKeychain.delete(account: passwordAccount)
    }

    private func refreshLoginState() {
        guard let url = URL(string: domain),
              let cookies = HTTPCookieStorage.shared.cookies(for: url) else {
            isLoggedIn = false
            return
        }
        isLoggedIn = cookies.contains { $0.name == "remix_userkey" } &&
                    cookies.contains { $0.name == "remix_userid" }
    }

    // MARK: - Login

    func login(email: String, password: String, remember: Bool = true) async throws {
        prepareNetworkPolicy()
        guard let url = URL(string: domain + "/rpc.php") else {
            throw ZLibError.network("Bad domain")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let body = [
            "isModal=true",
            "email=\(percent(email))",
            "password=\(percent(password))",
            "site_mode=books",
            "action=login",
            "isSingleLogin=1",
            "redirectUrl=",
            "gg_json_mode=1"
        ].joined(separator: "&")
        req.httpBody = body.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ZLibError.network(Self.describeNetworkError(error, url: url))
        }

        // The login response is JSON. Two shapes:
        //   success: {"response":{}}              (with Set-Cookie remix_userkey)
        //   failure: {"response":{"validationError":true,"message":"..."}}
        guard let httpResp = response as? HTTPURLResponse,
              (200...299).contains(httpResp.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ZLibError.loginFailed("HTTP \(code)")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let resp = json["response"] as? [String: Any] {
            if resp["validationError"] as? Bool == true {
                let msg = (resp["message"] as? String) ?? "Invalid credentials"
                throw ZLibError.loginFailed(msg)
            }
        }

        refreshLoginState()
        guard isLoggedIn else {
            throw ZLibError.loginFailed("Server didn't return a session cookie")
        }
        if remember {
            persistCredentials(email: email, password: password)
        }
    }

    func logout() {
        if let url = URL(string: domain),
           let cookies = HTTPCookieStorage.shared.cookies(for: url) {
            for c in cookies { HTTPCookieStorage.shared.deleteCookie(c) }
        }
        isLoggedIn = false
        limits = nil
    }

    // MARK: - Network diagnostics

    func runConnectivityDiagnostic() async -> ZLibDiagnosticReport {
        prepareNetworkPolicy()
        let checkedDomain = domain
        var steps: [ZLibDiagnosticStep] = [
            ZLibDiagnosticStep(
                status: .info,
                title: "Endpoint",
                detail: "\(checkedDomain) using \(dnsMode.label) DNS. \(dnsMode.detail)")
        ]

        guard let baseURL = URL(string: checkedDomain),
              let host = baseURL.host,
              let rpcURL = URL(string: checkedDomain + "/rpc.php") else {
            steps.append(ZLibDiagnosticStep(
                status: .failed,
                title: "Domain format",
                detail: "The endpoint is not a valid URL. Use a full HTTPS domain."))
            return ZLibDiagnosticReport(generatedAt: Date(),
                                        domain: checkedDomain,
                                        dnsMode: dnsMode,
                                        steps: steps)
        }

        steps.append(await cloudflareDoHProbe(host: host))
        steps.append(await rpcProbe(url: rpcURL))

        return ZLibDiagnosticReport(generatedAt: Date(),
                                    domain: checkedDomain,
                                    dnsMode: dnsMode,
                                    steps: steps)
    }

    private func cloudflareDoHProbe(host: String) async -> ZLibDiagnosticStep {
        guard var comps = URLComponents(string: "https://cloudflare-dns.com/dns-query") else {
            return ZLibDiagnosticStep(status: .failed,
                                      title: "Cloudflare DoH",
                                      detail: "Could not build the DNS-over-HTTPS test URL.")
        }
        comps.queryItems = [
            URLQueryItem(name: "name", value: host),
            URLQueryItem(name: "type", value: "A")
        ]
        guard let url = comps.url else {
            return ZLibDiagnosticStep(status: .failed,
                                      title: "Cloudflare DoH",
                                      detail: "Could not encode the hostname for DNS-over-HTTPS.")
        }

        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: Self.makeSessionConfiguration(requestTimeout: 12,
                                                                              resourceTimeout: 20))
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ZLibDiagnosticStep(status: .failed,
                                          title: "Cloudflare DoH",
                                          detail: "No HTTP response from the DNS resolver.")
            }
            guard (200...299).contains(http.statusCode) else {
                return ZLibDiagnosticStep(status: .failed,
                                          title: "Cloudflare DoH",
                                          detail: "Resolver HTTP \(http.statusCode).")
            }
            let decoded = try JSONDecoder().decode(DoHJSONResponse.self, from: data)
            let answers = (decoded.answer ?? [])
                .filter { $0.type == 1 }
                .map(\.data)
            if decoded.status == 0, !answers.isEmpty {
                return ZLibDiagnosticStep(status: .ok,
                                          title: "Cloudflare DoH",
                                          detail: "\(host) resolves to \(answers.joined(separator: ", ")).")
            }
            return ZLibDiagnosticStep(status: .warning,
                                      title: "Cloudflare DoH",
                                      detail: "Resolver answered status \(decoded.status), but no A record was returned.")
        } catch {
            return ZLibDiagnosticStep(status: .failed,
                                      title: "Cloudflare DoH",
                                      detail: Self.describeNetworkError(error, url: url))
        }
    }

    private func rpcProbe(url: URL) async -> ZLibDiagnosticStep {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: Self.makeSessionConfiguration(requestTimeout: 15,
                                                                              resourceTimeout: 20))
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ZLibDiagnosticStep(status: .failed,
                                          title: "App HTTP probe",
                                          detail: "No HTTP response from \(url.host ?? "host").")
            }
            if (200...399).contains(http.statusCode) {
                return ZLibDiagnosticStep(status: .ok,
                                          title: "App HTTP probe",
                                          detail: "\(url.lastPathComponent) returned HTTP \(http.statusCode). The app can reach the endpoint.")
            }
            return ZLibDiagnosticStep(status: .warning,
                                      title: "App HTTP probe",
                                      detail: "\(url.lastPathComponent) returned HTTP \(http.statusCode). DNS worked, but the endpoint may reject this request.")
        } catch {
            return ZLibDiagnosticStep(status: .failed,
                                      title: "App HTTP probe",
                                      detail: Self.describeNetworkError(error, url: url))
        }
    }

    private struct DoHJSONResponse: Decodable {
        let status: Int
        let answer: [DoHJSONAnswer]?

        enum CodingKeys: String, CodingKey {
            case status = "Status"
            case answer = "Answer"
        }
    }

    private struct DoHJSONAnswer: Decodable {
        let type: Int
        let data: String
    }

    private static func describeNetworkError(_ error: Error, url: URL?) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }
        let host = url?.host ?? "host"
        switch urlError.code {
        case .cannotFindHost:
            return "DNS failed for \(host). Try Encrypted DNS in Network debug."
        case .notConnectedToInternet:
            return "The device is offline."
        case .timedOut:
            return "Connection to \(host) timed out."
        case .cannotConnectToHost:
            return "\(host) resolved, but the connection was refused or blocked."
        case .secureConnectionFailed, .serverCertificateUntrusted,
                .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                .serverCertificateHasUnknownRoot:
            return "TLS/certificate failed for \(host): \(urlError.localizedDescription)"
        default:
            return urlError.localizedDescription
        }
    }

    // MARK: - Search

    func search(query: String,
                page: Int = 1,
                ext: ZLibExtension = .any,
                language: ZLibLanguage = .any,
                yearFrom: Int? = nil,
                yearTo: Int? = nil) async throws -> [ZLibSearchResult] {
        guard isLoggedIn else { throw ZLibError.notLoggedIn }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Path component: keep special chars (the Go library uses url.PathEscape).
        let path = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed

        var comps = URLComponents(string: domain + "/s/" + path)!
        var items: [URLQueryItem] = [.init(name: "page", value: String(page))]
        if let e = ext.queryValue { items.append(.init(name: "extensions[]", value: e)) }
        if let l = language.queryValue { items.append(.init(name: "languages[]", value: l)) }
        if let y = yearFrom { items.append(.init(name: "yearFrom", value: String(y))) }
        if let y = yearTo { items.append(.init(name: "yearTo", value: String(y))) }
        comps.queryItems = items

        guard let url = comps.url else { throw ZLibError.network("Bad search URL") }
        let html = try await getHTML(url)
        return parseSearchResults(html)
    }

    // MARK: - Book detail

    func fetchBookDetail(detailPath: String) async throws -> ZLibBookDetail {
        guard isLoggedIn else { throw ZLibError.notLoggedIn }
        let absolute = detailPath.hasPrefix("http") ? detailPath : domain + detailPath
        guard let url = URL(string: absolute) else { throw ZLibError.network("Bad detail URL") }
        let html = try await getHTML(url)
        return try parseBookDetail(html: html, fallbackPath: detailPath)
    }

    // MARK: - Download

    func download(downloadURL: URL,
                  destinationDir: URL,
                  onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        guard isLoggedIn else { throw ZLibError.notLoggedIn }
        var req = URLRequest(url: downloadURL)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(domain + "/", forHTTPHeaderField: "Referer")

        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (asyncBytes, response) = try await session.bytes(for: req)
        } catch {
            throw ZLibError.downloadFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ZLibError.downloadFailed("No HTTP response")
        }
        if http.statusCode == 200 && http.mimeType?.contains("text/html") == true {
            // Server returned a login wall in place of the file.
            throw ZLibError.sessionExpired
        }
        guard (200...299).contains(http.statusCode) else {
            throw ZLibError.downloadFailed("HTTP \(http.statusCode)")
        }

        let total = http.expectedContentLength
        let filename = filenameFromResponse(http) ?? "book.bin"
        let cleaned = cleanZLibFilename(filename)
        try FileManager.default.createDirectory(at: destinationDir,
                                                withIntermediateDirectories: true)
        let target = destinationDir.appendingPathComponent(cleaned)

        // Stream to disk in chunks so memory stays small even for big PDFs.
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(32 * 1024)
        var written: Int64 = 0

        do {
            for try await byte in asyncBytes {
                buffer.append(byte)
                if buffer.count >= 32 * 1024 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    onProgress(written, total)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                onProgress(written, total)
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw ZLibError.downloadFailed(error.localizedDescription)
        }

        return target
    }

    // MARK: - Image fetch (cover thumbnails)
    //
    // Cover CDN URLs reject AsyncImage's default request (no UA, no Referer).
    // Fetching through our session pulls in the browser UA + cookies set at
    // session level; we add the Referer manually.

    func fetchImageData(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(domain + "/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw ZLibError.network("HTTP \(http.statusCode)")
        }
        return data
    }

    // MARK: - Limits / quota

    @discardableResult
    func fetchLimits() async throws -> ZLibLimits {
        guard isLoggedIn else { throw ZLibError.notLoggedIn }
        guard let url = URL(string: domain + "/users/downloads") else {
            throw ZLibError.network("Bad limits URL")
        }
        let html = try await getHTML(url)
        let parsed = parseLimits(html: html)
        limits = parsed
        return parsed
    }

    // MARK: - Core HTTP w/ Cloudflare challenge solver

    private func getHTML(_ url: URL) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(domain + "/", forHTTPHeaderField: "Referer")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ZLibError.network(error.localizedDescription)
        }
        let body = String(data: data, encoding: .utf8) ?? ""

        // Login wall: any `id="loginForm"` in the markup means cookies expired.
        if body.contains("id=\"loginForm\"") {
            isLoggedIn = false
            throw ZLibError.sessionExpired
        }

        // Small page + challenge magic → solve SHA-1 PoW and retry once.
        if data.count < 20000,
           let token = try? solveCloudflareChallenge(html: body) {
            setCookie(name: "c_token", value: token, for: url)
            // Retry once.
            let (data2, _) = try await session.data(for: req)
            let body2 = String(data: data2, encoding: .utf8) ?? ""
            if body2.contains("id=\"loginForm\"") {
                isLoggedIn = false
                throw ZLibError.sessionExpired
            }
            return body2
        }

        // Successful (status code already implicit since URLSession follows
        // redirects). For other 4xx/5xx we still return the body — search /
        // detail parsers will simply find no results.
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw ZLibError.network("HTTP \(http.statusCode)")
        }
        return body
    }

    // MARK: - Cloudflare PoW

    /// Looks for `'<40hex>','c_token='` in the page, then brute-forces an
    /// integer `i` such that `sha1(<hex>+i)[n1]==0xb0 && [n1+1]==0x0b`, where
    /// `n1 = int(hex[0], 16)`. Returns the c_token cookie value.
    private func solveCloudflareChallenge(html: String) throws -> String? {
        let pattern = #"'([0-9A-Fa-f]{40})','c_token='"#
        let re = try NSRegularExpression(pattern: pattern)
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = re.firstMatch(in: html, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let c = String(html[r])
        guard let n1 = Int(String(c.first!), radix: 16) else { return nil }

        // Max 10M iterations — matches the Go library cap.
        let cBytes = Array(c.utf8)
        var prefix = cBytes
        for i in 0..<10_000_000 {
            let suffix = Array(String(i).utf8)
            var input = prefix
            input.append(contentsOf: suffix)
            let h = Array(Insecure.SHA1.hash(data: Data(input)))
            if h[n1] == 0xb0 && h[n1 + 1] == 0x0b {
                return c + String(i)
            }
            // Reset prefix capacity occasionally — avoid pathological growth.
            if i & 0xFFFF == 0 { prefix = cBytes }
        }
        return nil
    }

    private func setCookie(name: String, value: String, for url: URL) {
        let cookie = HTTPCookie(properties: [
            .domain: url.host ?? "z-lib.sk",
            .path: "/",
            .name: name,
            .value: value,
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(60 * 60 * 24)
        ])
        if let cookie {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    // MARK: - URL helpers

    private func percent(_ s: String) -> String {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
    }

    private func filenameFromResponse(_ http: HTTPURLResponse) -> String? {
        if let cd = http.value(forHTTPHeaderField: "Content-Disposition") {
            // Try filename="..."
            if let r = cd.range(of: #"filename\*?=(?:UTF-8'')?\"?([^\";]+)\"?"#,
                                options: .regularExpression) {
                let raw = String(cd[r])
                if let nameRange = raw.range(of: "=") {
                    var name = String(raw[raw.index(after: nameRange.lowerBound)...])
                    name = name.replacingOccurrences(of: "\"", with: "")
                    name = name.removingPercentEncoding ?? name
                    name = name.replacingOccurrences(of: "UTF-8''", with: "")
                    return name
                }
            }
        }
        // Fall back to URL last component.
        let last = http.url?.lastPathComponent ?? ""
        return last.isEmpty ? nil : last
    }

    /// Removes the trailing ` (z-library.sk, ...)` / `(z-lib.org)` suffix the
    /// site appends to many downloads. Mirrors the Go cleanFilename.
    private func cleanZLibFilename(_ raw: String) -> String {
        var s = raw
        let patterns = [
            #"\s*\(z-lib(?:rary)?\.(?:sk|org|to|id)[^)]*\)"#,
            #"\s*\(Z-Library[^)]*\)"#
        ]
        for p in patterns {
            if let range = s.range(of: p, options: .regularExpression) {
                s.removeSubrange(range)
            }
        }
        // Strip invalid filesystem chars.
        let invalid = CharacterSet(charactersIn: "/:")
        s = String(s.unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) }.map { $0 })
        return s.isEmpty ? "book.bin" : s
    }

    // MARK: - HTML parsing

    /// Parses every `<z-bookcard ...>...</z-bookcard>` block from a search
    /// result page. Scoped to `#searchResultBox` so we don't pick up cards
    /// rendered in "Most popular" / "Recently added" sidebars elsewhere on the
    /// page — those polluted results badly before the scope was added.
    func parseSearchResults(_ html: String) -> [ZLibSearchResult] {
        let region = isolateSearchRegion(html)
        let blocks = matchAll(in: region, pattern: #"<z-bookcard\b([\s\S]*?)</z-bookcard>"#,
                              group: 1)
        var out: [ZLibSearchResult] = []
        var seen: Set<String> = []
        for block in blocks {
            let attrs = parseAttributes(block)
            let href = attrs["href"] ?? ""
            // Some layouts drop the `id` attr but always carry `href` as
            // `/book/<id>/...`. Derive the id from href as a fallback so we
            // don't silently throw real results away.
            let derivedID = firstMatch(in: href, pattern: #"/book/(\d+)"#, group: 1) ?? ""
            let id = (attrs["id"] ?? "").isEmpty ? derivedID : attrs["id"]!
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)

            // Slotted children. Title can be on <div>, <span>, <a>, ...
            let title = firstMatch(in: block,
                                   pattern: #"<[A-Za-z0-9]+\s+[^>]*slot=\"title\"[^>]*>([\s\S]*?)</"#,
                                   group: 1)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Skip entries with no title — those are usually skeleton stubs.
            guard !title.isEmpty else { continue }

            let author = firstMatch(in: block,
                                    pattern: #"<[A-Za-z0-9]+\s+[^>]*slot=\"author\"[^>]*>([\s\S]*?)</"#,
                                    group: 1)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // Cover URL: lazy-loaded images use `data-src`; non-lazy use
            // `src`. Strip HTML entities for safety.
            let coverRaw = coverURLFromCard(block)

            let result = ZLibSearchResult(
                id: id,
                title: decodeHTML(stripTags(title)),
                authors: author.isEmpty ? [] : [decodeHTML(stripTags(author))],
                publisher: decodeHTML(attrs["publisher"] ?? ""),
                year: attrs["year"] ?? "",
                language: attrs["language"] ?? "",
                ext: (attrs["extension"] ?? "").uppercased(),
                filesize: attrs["filesize"] ?? "",
                rating: attrs["rating"] ?? "",
                coverURL: coverRaw.flatMap { absoluteURL(decodeHTML($0)) },
                detailPath: href,
                isbn: attrs["isbn"] ?? "")
            out.append(result)
        }
        return out
    }

    /// Narrows the markup to the `#searchResultBox` container so we ignore
    /// sidebar suggestions / popular sections that share the `<z-bookcard>`
    /// custom element. Falls back to the full document if the marker is
    /// missing (e.g., site rewrote its layout).
    private func isolateSearchRegion(_ html: String) -> String {
        guard let start = html.range(of: "id=\"searchResultBox\"")
                ?? html.range(of: "id='searchResultBox'") else {
            return html
        }
        let after = html[start.upperBound...]
        // Stop at the next major outer marker we know of. These markers tend
        // to come AFTER the result list in z-lib's templates.
        let stoppers = ["<footer", "id=\"footer\"", "id='footer'",
                        "class=\"footer\"", "class=\"footer-section\"",
                        "id=\"asideHelper\""]
        var end = after.endIndex
        for s in stoppers {
            if let r = after.range(of: s), r.lowerBound < end {
                end = r.lowerBound
            }
        }
        return String(after[..<end])
    }

    /// Z-lib markup variation: img inside z-bookcard sometimes carries
    /// `data-src`, `data-original-src`, or just `src`. We also accept absent
    /// `slot="cover"` (some templates put the only img bare).
    private func coverURLFromCard(_ block: String) -> String? {
        let patterns = [
            #"<img[^>]*slot=\"cover\"[^>]*?data-src=\"([^\"]+)\""#,
            #"<img[^>]*slot=\"cover\"[^>]*?src=\"([^\"]+)\""#,
            #"<img[^>]*?data-flickity-lazyload=\"([^\"]+)\""#,
            #"<img[^>]*?data-src=\"([^\"]+)\""#,
            #"<img[^>]*?src=\"([^\"]+)\""#
        ]
        for p in patterns {
            if let m = firstMatch(in: block, pattern: p, group: 1) {
                let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
                // Filter pixel-placeholder gifs / dataurls that some lazy
                // libraries inject as initial src.
                if trimmed.isEmpty { continue }
                if trimmed.hasPrefix("data:") { continue }
                if trimmed.contains("placeholder") { continue }
                return trimmed
            }
        }
        return nil
    }

    /// Parses the `/book/<id>/...` detail page. The bulk of fields are inside
    /// `.property_*` blocks; the download link is on `a.addDownloadedBook`,
    /// falling back to any `a[href*="/dl/"]` or `a[href*="/file/"]`.
    func parseBookDetail(html: String, fallbackPath: String) throws -> ZLibBookDetail {
        let id = firstMatch(in: fallbackPath,
                            pattern: #"/book/(\d+)"#,
                            group: 1) ?? ""

        let title = firstMatch(in: html,
                               pattern: #"<h1[^>]*itemprop=\"name\"[^>]*>([\s\S]*?)</h1>"#,
                               group: 1)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? firstMatch(in: html,
                          pattern: #"<title>([\s\S]*?)</title>"#, group: 1)
            ?? "(untitled)"

        let authors = matchAll(in: html,
                               pattern: #"<i[^>]*class=\"[^\"]*\bauthors\b[^\"]*\"[^>]*>([\s\S]*?)</i>"#,
                               group: 1).flatMap {
            matchAll(in: $0, pattern: #"<a[^>]*>([\s\S]*?)</a>"#, group: 1)
                .map { decodeHTML($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        let description = firstMatch(in: html,
                                     pattern: #"id=\"bookDescriptionBox\"[^>]*>([\s\S]*?)</div>"#,
                                     group: 1)
            .map { stripTags($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        func prop(_ key: String) -> String? {
            let pattern = #"property_"# + key + #"[\s\S]*?property_value[^>]*>([\s\S]*?)</div>"#
            return firstMatch(in: html, pattern: pattern, group: 1)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&nbsp;", with: " ")
        }

        let year = prop("year")
        let publisher = prop("publisher").map { stripTags($0) }
        let language = prop("language")
        let categories = prop("categories").map { stripTags($0) }
        let file = prop("_file").map { stripTags($0) }
        let (ext, size) = parseFileProperty(file)
        let isbn = prop("isbn") ?? prop("isbn13") ?? prop("isbn10")

        // Cover: <z-cover><img class="image" src="..."> OR og:image meta tag.
        let cover = firstMatch(in: html,
                               pattern: #"<img[^>]*class=\"[^\"]*\bimage\b[^\"]*\"[^>]*?src=\"([^\"]+)\""#,
                               group: 1)
            ?? firstMatch(in: html,
                          pattern: #"<meta[^>]*property=\"og:image\"[^>]*content=\"([^\"]+)\""#,
                          group: 1)

        // Download URL.
        let dl = firstMatch(in: html,
                            pattern: #"<a[^>]*class=\"[^\"]*addDownloadedBook[^\"]*\"[^>]*href=\"([^\"]+)\""#,
                            group: 1)
            ?? firstMatch(in: html,
                          pattern: #"<a[^>]*href=\"(/(?:dl|file)/[^\"]+)\""#, group: 1)

        return ZLibBookDetail(
            id: id,
            title: decodeHTML(title),
            authors: authors,
            coverURL: cover.flatMap { URL(string: $0) },
            description: description.map { decodeHTML($0) },
            year: year,
            publisher: publisher.map { decodeHTML($0) },
            language: language,
            ext: ext?.uppercased(),
            size: size,
            isbn: isbn,
            categories: categories.map { decodeHTML($0) },
            downloadURL: dl.flatMap { absoluteURL($0) })
    }

    private func parseFileProperty(_ raw: String?) -> (String?, String?) {
        guard let raw else { return (nil, nil) }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count >= 2 { return (parts[0], parts[1]) }
        if parts.count == 1 { return (parts[0], nil) }
        return (nil, nil)
    }

    private func parseLimits(html: String) -> ZLibLimits {
        let count = firstMatch(in: html,
                               pattern: #"class=\"[^\"]*\bd-count\b[^\"]*\"[^>]*>([\s\S]*?)</"#,
                               group: 1)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = count.split(separator: "/")
        let used = parts.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let total = parts.dropFirst().first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let reset = firstMatch(in: html,
                               pattern: #"class=\"[^\"]*\bd-reset\b[^\"]*\"[^>]*>([\s\S]*?)</"#,
                               group: 1)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ZLibLimits(dailyUsed: used, dailyAllowed: total, resetIn: reset)
    }

    // MARK: - HTML utility primitives

    private func absoluteURL(_ pathOrURL: String) -> URL? {
        if pathOrURL.hasPrefix("http") { return URL(string: pathOrURL) }
        if pathOrURL.hasPrefix("//") { return URL(string: "https:" + pathOrURL) }
        if pathOrURL.hasPrefix("/") { return URL(string: domain + pathOrURL) }
        return URL(string: domain + "/" + pathOrURL)
    }

    private func parseAttributes(_ openTagRegion: String) -> [String: String] {
        // Trim everything past the first '>' so we don't pick up attributes
        // inside child elements (matchAll captures the whole block content).
        var headerEnd = openTagRegion.endIndex
        if let r = openTagRegion.firstIndex(of: ">") { headerEnd = r }
        let header = String(openTagRegion[..<headerEnd])
        var out: [String: String] = [:]
        let pattern = #"([A-Za-z_:][A-Za-z0-9_\-:.]*)\s*=\s*\"([^\"]*)\""#
        for m in matchAllMulti(in: header, pattern: pattern) {
            out[m[1].lowercased()] = m[2]
        }
        return out
    }

    private func firstMatch(in s: String, pattern: String, group: Int) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = re.firstMatch(in: s, range: range),
              group < m.numberOfRanges,
              let r = Range(m.range(at: group), in: s) else { return nil }
        return String(s[r])
    }

    private func matchAll(in s: String, pattern: String, group: Int) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: [.caseInsensitive]) else { return [] }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.matches(in: s, range: range).compactMap { m in
            guard group < m.numberOfRanges,
                  let r = Range(m.range(at: group), in: s) else { return nil }
            return String(s[r])
        }
    }

    private func matchAllMulti(in s: String, pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: []) else { return [] }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.matches(in: s, range: range).map { m in
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                if let r = Range(m.range(at: i), in: s) {
                    groups.append(String(s[r]))
                } else {
                    groups.append("")
                }
            }
            return groups
        }
    }

    private func stripTags(_ s: String) -> String {
        let pattern = #"<[^>]+>"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func decodeHTML(_ s: String) -> String {
        var out = s
        let map: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " ")
        ]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        // Numeric entities &#NNNN;
        let pattern = #"&#(\d+);"#
        if let re = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            let matches = re.matches(in: out, range: range).reversed()
            for m in matches {
                guard let mr = Range(m.range, in: out),
                      let gr = Range(m.range(at: 1), in: out),
                      let code = UInt32(out[gr]),
                      let scalar = Unicode.Scalar(code) else { continue }
                out.replaceSubrange(mr, with: String(Character(scalar)))
            }
        }
        return out
    }
}

// MARK: - Backgroundable downloads
//
// The original startDownload lived inside DiscoverBookSheet's @State, so a
// user dismissing the sheet either cancelled the Task or left it orphaned
// with no way to surface completion. These two methods move the state into
// the service itself: the sheet observes `activeDownload`, and the user can
// close the sheet at any time — the download keeps running in the
// background, imports into BookStore on success, and reports the result
// through `activeDownload` for any view that wants to listen.

extension ZLibService {
    /// Kick off a download + import as a background task tied to the
    /// service's lifetime (not to a transient view). Becomes a no-op if
    /// another download is already in flight — callers can check
    /// `activeDownload.isActive` first.
    func startBackgroundDownload(seed: ZLibSearchResult,
                                  detail: ZLibBookDetail,
                                  into store: BookStore) {
        guard !activeDownload.isActive else { return }
        guard let url = detail.downloadURL else {
            activeDownload = .failed(book: seed, message: "No download link.")
            return
        }
        activeDownload = .downloading(book: seed, receivedBytes: 0, totalBytes: 0)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zlib_download", isDirectory: true)
        Task { [weak self] in
            guard let self else { return }
            do {
                let fileURL = try await self.download(downloadURL: url,
                                                       destinationDir: tempDir) { done, total in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .downloading(let book, _, _) = self.activeDownload {
                            self.activeDownload = .downloading(book: book,
                                                                receivedBytes: done,
                                                                totalBytes: total)
                        }
                    }
                }
                await MainActor.run {
                    self.activeDownload = .importing(book: seed)
                }
                let imported = try await MainActor.run {
                    try store.importBook(from: fileURL)
                }
                try? FileManager.default.removeItem(at: fileURL)
                Task { try? await self.fetchLimits() }
                await MainActor.run {
                    self.activeDownload = .completed(book: seed,
                                                     importedBookID: imported.id)
                }
            } catch {
                await MainActor.run {
                    self.activeDownload = .failed(book: seed,
                                                  message: error.localizedDescription)
                }
            }
        }
    }

    /// Reset back to .idle so a new download can start. Called by the UI
    /// after the user has seen the completed/failed banner.
    func acknowledgeDownload() {
        // Don't clobber a running download — only ack terminal states.
        switch activeDownload {
        case .completed, .failed:
            activeDownload = .idle
        default:
            break
        }
    }
}
