import CryptoKit
import Foundation
import UIKit

// MARK: - Device File State

/// Where this book stands on the CrossPoint device, as last seen at sync time.
enum DeviceFileState: String, Codable {
    case absent       // no entry on device
    case filePresent  // entry + file on device, ready to read
    case entryOnly    // entry on device, file freed for space

    var isOnDevice: Bool { self != .absent }
    var hasFile: Bool { self == .filePresent }
}

// MARK: - Book

struct Book: Identifiable, Codable, Equatable {
    let id: UUID
    var filename: String
    var addedDate: Date
    var fileSize: Int64
    /// Library-level metadata (title/author/cover/etc.). Defaults to
    /// `.filename` source on import; populated by EPUB extraction or online
    /// lookup. Reading state lives in a separate per-book sidecar — see
    /// ReadingStateStore.
    var metadata: BookMetadata

    /// Author-aware display title: prefers metadata.title when set,
    /// otherwise derives a presentable string from the filename.
    var displayTitle: String {
        if let t = metadata.title, !t.isEmpty { return t }
        var name = (filename as NSString).deletingPathExtension
        name = name.replacingOccurrences(of: "_", with: " ")
        name = name.replacingOccurrences(of: "-", with: " ")
        return name
    }

    var ext: String {
        (filename as NSString).pathExtension.lowercased()
    }

    init(id: UUID,
         filename: String,
         addedDate: Date,
         fileSize: Int64,
         metadata: BookMetadata = BookMetadata(source: .filename)) {
        self.id = id
        self.filename = filename
        self.addedDate = addedDate
        self.fileSize = fileSize
        self.metadata = metadata
    }

    /// Backward-compatible decoder: v1 payloads (no `metadata` field) get a
    /// default empty metadata block so old books_meta.json files load
    /// cleanly. On the next save() the file is rewritten with v2 schema.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.filename = try c.decode(String.self, forKey: .filename)
        self.addedDate = try c.decode(Date.self, forKey: .addedDate)
        self.fileSize = try c.decode(Int64.self, forKey: .fileSize)
        self.metadata = try c.decodeIfPresent(BookMetadata.self, forKey: .metadata)
            ?? BookMetadata(source: .filename)
    }

    private enum CodingKeys: String, CodingKey {
        case id, filename, addedDate, fileSize, metadata
    }
}

// MARK: - Errors

enum BookImportError: LocalizedError {
    case unsupportedFormat
    case copyFailed(Error)
    case duplicate(existingTitle: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Unsupported format. Use EPUB, TXT, BMP, XTC or XTCH."
        case .copyFailed(let e):
            return "Import failed: \(e.localizedDescription)"
        case .duplicate(let title):
            return "Already in your library as “\(title)”."
        }
    }
}

// MARK: - Persistent snapshot

private struct DeviceStateSnapshot: Codable {
    // UUID.uuidString → DeviceFileState.rawValue, so the on-disk JSON stays
    // human-readable rather than the alternating-array form Codable produces
    // for non-String dictionary keys.
    var states: [String: String]
    var sentBookIDs: [String]
    var pendingFileRemovals: [String] = []
}

// MARK: - BookStore

@Observable
class BookStore {
    var books: [Book] = []

    /// Last-known device file state per book ID. Books not in this map have
    /// never been seen on the device.
    private(set) var deviceStates: [UUID: DeviceFileState] = [:]

    /// Every book ID this app has ever sent to the device. Used as a tombstone
    /// set: a book in `sentBookIDs` but no longer in `books` is queued for
    /// DELETE_ENTRY on the next sync.
    private(set) var sentBookIDs: Set<UUID> = []

    /// Book IDs the user explicitly asked to free from the device (keep the
    /// entry, drop the file). Drained by the sync flow.
    private(set) var pendingFileRemovals: Set<UUID> = []

    private let booksDir: URL
    private let coversDir: URL
    private let metaURL: URL
    private let deviceStateURL: URL
    private let legacyDeviceLibraryURL: URL

    static let supportedExtensions = Set(["epub", "txt", "bmp", "xtc", "xtch"])

    init(documentsDirectory: URL? = nil) {
        let docs = documentsDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        booksDir = docs.appendingPathComponent("Books", isDirectory: true)
        coversDir = docs.appendingPathComponent("Covers", isDirectory: true)
        metaURL = docs.appendingPathComponent("books_meta.json")
        deviceStateURL = docs.appendingPathComponent("device_state.json")
        legacyDeviceLibraryURL = docs.appendingPathComponent("device_library.json")
        try? FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
        loadMeta()
        loadDeviceState()
    }

    // MARK: - Metadata mutations

    func updateMetadata(_ metadata: BookMetadata, for book: Book) {
        guard let idx = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[idx].metadata = metadata
        saveMeta()
    }

    // MARK: - Cover persistence

    /// Resize a raw cover image (JPEG/PNG bytes) to ≤384pt longest side,
    /// re-encode as JPEG, and persist under Documents/Covers/. Returns the
    /// generated asset ID for storage in `BookMetadata.coverAssetID`.
    func saveCoverData(_ data: Data) -> UUID? {
        guard let original = UIImage(data: data) else { return nil }
        let maxDim: CGFloat = 384
        let size = original.size
        let scale = min(maxDim / size.width, maxDim / size.height, 1.0)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            original.draw(in: CGRect(origin: .zero, size: newSize))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.82) else { return nil }
        let assetID = UUID()
        let url = coversDir.appendingPathComponent("\(assetID.uuidString).jpg")
        do {
            try jpeg.write(to: url, options: .atomic)
            return assetID
        } catch {
            return nil
        }
    }

    func coverFileURL(for assetID: UUID) -> URL {
        coversDir.appendingPathComponent("\(assetID.uuidString).jpg")
    }

    func removeCover(assetID: UUID) {
        try? FileManager.default.removeItem(at: coverFileURL(for: assetID))
    }

    // MARK: - Per-book queries

    func deviceState(for book: Book) -> DeviceFileState {
        deviceStates[book.id] ?? .absent
    }

    func isOnDevice(_ book: Book) -> Bool {
        deviceState(for: book).isOnDevice
    }

    func hasFileOnDevice(_ book: Book) -> Bool {
        deviceState(for: book).hasFile
    }

    func wasSentToDevice(_ book: Book) -> Bool {
        sentBookIDs.contains(book.id)
    }

    // MARK: - Sync result application

    /// Replace device-state mapping after a full sync handshake. Any book ID
    /// not present in `report` is treated as absent (the device confirmed
    /// it doesn't have it). Stale tombstones are also cleared when their IDs
    /// don't appear on the device anymore.
    func applyDeviceReport(_ report: [UUID: DeviceFileState]) {
        var next: [UUID: DeviceFileState] = [:]
        for (id, state) in report {
            next[id] = state
        }
        deviceStates = next

        // Tombstones for IDs the device no longer knows about are satisfied.
        sentBookIDs = sentBookIDs.intersection(Set(report.keys))
        saveDeviceState()
    }

    func markUploaded(_ book: Book) {
        deviceStates[book.id] = .filePresent
        sentBookIDs.insert(book.id)
        saveDeviceState()
    }

    func markFileRemovedFromDevice(bookID: UUID) {
        deviceStates[bookID] = .entryOnly
        pendingFileRemovals.remove(bookID)
        saveDeviceState()
    }

    func markEntryRemovedFromDevice(bookID: UUID) {
        deviceStates.removeValue(forKey: bookID)
        sentBookIDs.remove(bookID)
        pendingFileRemovals.remove(bookID)
        saveDeviceState()
    }

    // MARK: - File-removal queue

    func queueFileRemoval(_ book: Book) {
        guard deviceState(for: book) == .filePresent else { return }
        pendingFileRemovals.insert(book.id)
        saveDeviceState()
    }

    func unqueueFileRemoval(_ book: Book) {
        pendingFileRemovals.remove(book.id)
        saveDeviceState()
    }

    func isFileRemovalQueued(_ book: Book) -> Bool {
        pendingFileRemovals.contains(book.id)
    }

    // MARK: - Sync planning helpers

    /// Books that need to be sent: in the local library, not currently on the
    /// device with a file. Books reported as `entryOnly` are NOT re-sent
    /// automatically — the user freed that space deliberately.
    func booksNeedingUpload() -> [Book] {
        books.filter { deviceState(for: $0) == .absent }
    }

    /// IDs that were on the device but are no longer in the local library.
    /// These are entries to remove on the device.
    func pendingEntryDeletions() -> [UUID] {
        let liveIDs = Set(books.map { $0.id })
        return Array(sentBookIDs.subtracting(liveIDs))
    }

    /// Total number of operations the next sync would perform.
    var pendingChangeCount: Int {
        booksNeedingUpload().count + pendingEntryDeletions().count + pendingFileRemovals.count
    }

    // MARK: - Library mutations

    func importBook(from url: URL) throws -> Book {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        guard BookStore.supportedExtensions.contains(ext) else {
            throw BookImportError.unsupportedFormat
        }

        // Content dedup: same size → compare SHA-256. Size gate keeps this
        // cheap — we only hash when a same-size book already exists.
        let incomingSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init)
        let sameSize = books.filter { $0.fileSize == incomingSize }
        if !sameSize.isEmpty, let incoming = try? Data(contentsOf: url) {
            let incomingHash = SHA256.hash(data: incoming)
            for existing in sameSize {
                if let data = try? fileData(for: existing),
                   SHA256.hash(data: data) == incomingHash {
                    throw BookImportError.duplicate(existingTitle: existing.displayTitle)
                }
            }
        }

        let originalName = url.lastPathComponent
        var destName = originalName
        var destURL = booksDir.appendingPathComponent(destName)
        var counter = 1
        while FileManager.default.fileExists(atPath: destURL.path) {
            let base = (originalName as NSString).deletingPathExtension
            destName = "\(base) (\(counter)).\(ext)"
            destURL = booksDir.appendingPathComponent(destName)
            counter += 1
        }

        do {
            try FileManager.default.copyItem(at: url, to: destURL)
        } catch {
            throw BookImportError.copyFailed(error)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let book = Book(id: UUID(), filename: destName, addedDate: Date(), fileSize: size)
        books.insert(book, at: 0)
        saveMeta()

        // Fire-and-forget metadata extraction. EPUB OPF parsing + cover
        // resize is too expensive for the picker callback path, but cheap
        // enough to run on a utility-priority task. Result merges into the
        // book on success; failure leaves the procedural cover.
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let extracted = await EpubMetadataExtractor().extract(from: destURL) else { return }
            await MainActor.run {
                guard let idx = self.books.firstIndex(where: { $0.id == book.id }) else { return }
                var metadata = self.books[idx].metadata
                if metadata.title == nil, let v = extracted.title { metadata.title = v }
                if metadata.author == nil, let v = extracted.author { metadata.author = v }
                if metadata.publisher == nil, let v = extracted.publisher { metadata.publisher = v }
                if metadata.publishedYear == nil, let v = extracted.publishedYear { metadata.publishedYear = v }
                if metadata.language == nil, let v = extracted.language { metadata.language = v }
                if metadata.isbn == nil, let v = extracted.isbn { metadata.isbn = v }
                if metadata.synopsis == nil, let v = extracted.synopsis { metadata.synopsis = v }
                if metadata.coverAssetID == nil, let data = extracted.coverData,
                   let assetID = self.saveCoverData(data) {
                    metadata.coverAssetID = assetID
                }
                if metadata.title != nil || metadata.author != nil ||
                   metadata.coverAssetID != nil {
                    metadata.source = .epubOpf
                    metadata.fetchedAt = Date()
                    self.updateMetadata(metadata, for: self.books[idx])
                }
            }
        }

        return book
    }

    /// Removes the book from the local library. The `deviceStates` /
    /// `sentBookIDs` entries are preserved as tombstones so the next sync
    /// can propagate the deletion to the device (DELETE_ENTRY).
    func deleteBook(_ book: Book) {
        try? FileManager.default.removeItem(at: fileURL(for: book))
        books.removeAll { $0.id == book.id }
        saveMeta()
    }

    func fileURL(for book: Book) -> URL {
        booksDir.appendingPathComponent(book.filename)
    }

    func fileData(for book: Book) throws -> Data {
        try Data(contentsOf: fileURL(for: book))
    }

    // MARK: - Persistence

    private func loadMeta() {
        guard let data = try? Data(contentsOf: metaURL) else { return }

        // Detect v1 (no `metadata` field on any entry) and snapshot before
        // the next save rewrites the file with v2 schema. The .bak is only
        // written once — subsequent runs are no-ops.
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           !raw.isEmpty,
           raw.allSatisfy({ $0["metadata"] == nil }) {
            let backup = metaURL.deletingPathExtension()
                .appendingPathExtension("v1.bak")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? data.write(to: backup, options: .atomic)
            }
        }

        guard let decoded = try? JSONDecoder().decode([Book].self, from: data) else { return }
        books = decoded.filter {
            FileManager.default.fileExists(atPath: fileURL(for: $0).path)
        }

        // Forward the on-disk file to v2 schema so old AI-paths that decode
        // without our custom init can't trip over a missing key later.
        if !books.isEmpty { saveMeta() }
    }

    private func saveMeta() {
        if let data = try? JSONEncoder().encode(books) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }

    private func loadDeviceState() {
        if let data = try? Data(contentsOf: deviceStateURL),
           let decoded = try? JSONDecoder().decode(DeviceStateSnapshot.self, from: data) {
            var states: [UUID: DeviceFileState] = [:]
            for (key, raw) in decoded.states {
                if let id = UUID(uuidString: key), let s = DeviceFileState(rawValue: raw) {
                    states[id] = s
                }
            }
            deviceStates = states
            sentBookIDs = Set(decoded.sentBookIDs.compactMap { UUID(uuidString: $0) })
            pendingFileRemovals = Set(decoded.pendingFileRemovals.compactMap { UUID(uuidString: $0) })
            return
        }
        // One-shot migration from the old Set<String> store (filenames).
        if let data = try? Data(contentsOf: legacyDeviceLibraryURL),
           let legacy = try? JSONDecoder().decode([String].self, from: data) {
            let byFilename = Dictionary(uniqueKeysWithValues: books.map { ($0.filename, $0.id) })
            for filename in legacy {
                if let id = byFilename[filename] {
                    deviceStates[id] = .filePresent
                    sentBookIDs.insert(id)
                }
            }
            saveDeviceState()
            try? FileManager.default.removeItem(at: legacyDeviceLibraryURL)
        }
    }

    private func saveDeviceState() {
        var states: [String: String] = [:]
        for (id, state) in deviceStates {
            states[id.uuidString] = state.rawValue
        }
        let snapshot = DeviceStateSnapshot(
            states: states,
            sentBookIDs: sentBookIDs.map { $0.uuidString },
            pendingFileRemovals: pendingFileRemovals.map { $0.uuidString }
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: deviceStateURL, options: .atomic)
        }
    }
}
