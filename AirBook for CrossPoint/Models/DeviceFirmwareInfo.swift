import Foundation

// MARK: - Device firmware info
//
// Parsed snapshot of the read-only Info characteristic exposed by the
// CrossPoint AirBook firmware (UUID 8b45f104-...). Plain text payload, one
// key=value pair per line. Unknown keys are silently dropped so adding new
// capabilities on the device doesn't break older app versions.

struct DeviceFirmwareInfo: Equatable {
    /// Firmware version string as reported by the device, e.g. "1.3.0" or
    /// "1.3.0-airbook.1+ab12cd3" for dev builds.
    let version: String
    /// Protocol version (book-sync handshake level). Bumped by the device
    /// when wire format changes.
    let proto: Int
    /// Capability tokens — at least "book", "sync", "ota" on AirBook builds.
    let capabilities: Set<String>
    /// Total kilobytes used by books in /AirBook on the SD card. nil if
    /// the firmware predates storage reporting (airbook.5+).
    let usedKB: Int?
    /// Number of books in /AirBook. nil if predates airbook.5.
    let bookCount: Int?

    var supportsOTA: Bool { capabilities.contains("ota") }
    var supportsBrowse: Bool { capabilities.contains("browse") }

    init(version: String, proto: Int, capabilities: Set<String>,
         usedKB: Int? = nil, bookCount: Int? = nil) {
        self.version = version
        self.proto = proto
        self.capabilities = capabilities
        self.usedKB = usedKB
        self.bookCount = bookCount
    }

    /// Parse the raw bytes from the Info characteristic. Tolerant: missing
    /// fields default; lines that don't contain '=' are skipped. Returns
    /// nil only if the payload is empty or non-UTF8.
    static func parse(_ data: Data) -> DeviceFirmwareInfo? {
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var version = ""
        var proto = 0
        var caps: Set<String> = []
        var usedKB: Int?
        var bookCount: Int?
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "fw":      version = value
            case "proto":   proto = Int(value) ?? 0
            case "caps":    caps = Set(value.split(separator: ",").map {
                                    $0.trimmingCharacters(in: .whitespaces)
                                })
            case "used_kb": usedKB = Int(value)
            case "books":   bookCount = Int(value)
            default: break
            }
        }
        return DeviceFirmwareInfo(version: version, proto: proto, capabilities: caps,
                                  usedKB: usedKB, bookCount: bookCount)
    }
}
