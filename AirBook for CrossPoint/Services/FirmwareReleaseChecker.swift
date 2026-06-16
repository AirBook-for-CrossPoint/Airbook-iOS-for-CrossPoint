import Foundation

// MARK: - Firmware release metadata

struct FirmwareReleaseInfo: Equatable {
    let tag: String              // e.g. "v1.3.0-airbook.1"
    let version: String          // tag without leading "v"
    let body: String
    let downloadURL: URL
    let sizeBytes: Int64
    let publishedAt: Date?

    /// Heuristic: device version != release version → an update is available.
    /// Both strings are treated as opaque tokens. The release tag is the
    /// canonical truth on iOS; the device only echoes the same string when
    /// installed.
    func isNewerThan(_ deviceVersion: String) -> Bool {
        let normalize: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
        let a = normalize(version)
        let b = normalize(deviceVersion)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a != b
    }
}

// MARK: - Release checker

enum FirmwareReleaseCheckerError: Error, LocalizedError {
    case offline
    case noFirmwareAsset
    case http(Int)
    case decode

    var errorDescription: String? {
        switch self {
        case .offline:           return "Couldn't reach GitHub."
        case .noFirmwareAsset:   return "Latest release has no firmware.bin asset."
        case .http(let code):    return "GitHub API returned HTTP \(code)."
        case .decode:            return "GitHub release payload couldn't be parsed."
        }
    }
}

@Observable
@MainActor
final class FirmwareReleaseChecker {
    private(set) var latest: FirmwareReleaseInfo?
    private(set) var lastCheckedAt: Date?
    private(set) var lastError: String?
    private(set) var isChecking = false

    /// The GitHub repo we publish AirBook firmware releases from. Fork
    /// transferred to the org — old Yoddikko URLs still 301 redirect, but
    /// using the canonical one avoids the extra hop.
    private let releasesURL = URL(string:
        "https://api.github.com/repos/AirBook-for-CrossPoint/crosspoint-reader-with-aribook/releases/latest")!

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "AirBook-iOS",
            "Accept": "application/vnd.github+json"
        ]
        session = URLSession(configuration: config)
    }

    /// Fetch the latest release. Cached for 5 minutes; pass force=true to
    /// bypass. Throws on transport/parsing errors but never on "no update
    /// available" — that's a successful state, the caller just compares
    /// against the device version.
    @discardableResult
    func refresh(force: Bool = false) async throws -> FirmwareReleaseInfo {
        if !force, let cached = latest,
           let when = lastCheckedAt,
           Date().timeIntervalSince(when) < 300 {
            return cached
        }
        isChecking = true
        defer { isChecking = false }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: releasesURL)
        } catch {
            lastError = error.localizedDescription
            throw FirmwareReleaseCheckerError.offline
        }
        guard let http = response as? HTTPURLResponse else {
            lastError = "Unexpected response"
            throw FirmwareReleaseCheckerError.decode
        }
        guard (200..<300).contains(http.statusCode) else {
            lastError = "HTTP \(http.statusCode)"
            throw FirmwareReleaseCheckerError.http(http.statusCode)
        }

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int64
        }
        struct Release: Decodable {
            let tag_name: String
            let body: String?
            let published_at: String?
            let assets: [Asset]
        }

        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            lastError = "Bad JSON"
            throw FirmwareReleaseCheckerError.decode
        }
        // We accept any .bin asset — the fork's release workflow produces
        // a single firmware.bin but historically other forks have used
        // "update.bin" or named after the tag. First match wins.
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".bin") }),
              let url = URL(string: asset.browser_download_url) else {
            lastError = "No .bin asset"
            throw FirmwareReleaseCheckerError.noFirmwareAsset
        }

        let iso = ISO8601DateFormatter()
        let publishedAt = release.published_at.flatMap(iso.date(from:))

        let info = FirmwareReleaseInfo(
            tag: release.tag_name,
            version: release.tag_name.hasPrefix("v")
                ? String(release.tag_name.dropFirst())
                : release.tag_name,
            body: release.body ?? "",
            downloadURL: url,
            sizeBytes: asset.size,
            publishedAt: publishedAt)

        latest = info
        lastCheckedAt = Date()
        lastError = nil
        return info
    }
}
