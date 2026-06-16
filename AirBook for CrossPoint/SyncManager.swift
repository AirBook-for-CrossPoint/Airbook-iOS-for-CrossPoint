import CoreBluetooth
import Foundation

// MARK: - Protocol Version
//
// V3 is strictly additive: same GATT service, same V2 commands for file ops
// (START_V2 / DELETE_ENTRY / DELETE_FILE / SYNC_END). What V3 adds:
//  - SYNC_START_V3 / SYNC_READY_V3:<free_kb>      (replaces SYNC_START_V2)
//  - LIST_V3 / FILE_V3:<uuid>:<has_file>:<size>:<has_progress>:<bmk>:<hl>:<name>
//  - QUERY_PROGRESS:<uuid>  →  PROGRESS_V3:<uuid>:<spine>:<page>:<count>:<percent_x10000>:<updated_ms>
//                              or PROGRESS_V3:<uuid>:NONE
//  - PUSH_PROGRESS:<uuid>:<spine>:<page>:<count>:<percent_x10000>:<updated_ms> → PROGRESS_OK:<uuid>
//  - QUERY_BOOKMARKS:<uuid> → BMK_V3 records (Status char), then BMK_END:<uuid>:<total>
//  - PUSH_BOOKMARKS:<uuid>:<count> → READY → binary blob on Data char → BMK_OK:<uuid>:<count>
//  - QUERY_HIGHLIGHTS / PUSH_HIGHLIGHTS (Phase 6, designed the same way)
//
// Fallback: if the device replies to SYNC_START_V3 with "ERROR:Unknown control
// message" we transparently retry SYNC_START_V2 and behave like the V2 client
// for the rest of the session (no reading-state sync).

enum ProtocolVersion: Equatable {
    case v2
    case v3(freeHeapKB: Int)

    var isV3: Bool {
        if case .v3 = self { return true }
        return false
    }
}

// MARK: - Sync Phase

enum SyncPhase: Equatable {
    case idle
    case scanning
    case connecting
    case handshake          // SYNC_START_V2 sent
    case listing            // LIST_V2 sent
    case executing(StepInfo)
    case finalizing         // SYNC_END sent
    case done(SyncSummary)
    case cancelled
    case error(String)

    struct StepInfo: Equatable {
        var label: String        // "Removing entries", "Freeing space", "Sending books"
        var current: Int         // 1-based index within current phase
        var total: Int           // ops in the current phase
        var bytesTransferred: Int64 = 0
        var bytesTotal: Int64 = 0
    }

    var isActive: Bool {
        switch self {
        case .idle, .done, .cancelled, .error: return false
        default: return true
        }
    }

    var statusMessage: String {
        switch self {
        case .idle:                 return "Ready to sync"
        case .scanning:             return "Searching for CrossPoint..."
        case .connecting:           return "Connecting..."
        case .handshake:            return "Connecting to AirBook..."
        case .listing:              return "Reading device library..."
        case .executing(let s):     return s.total > 0 ? "\(s.label) (\(s.current)/\(s.total))" : s.label
        case .finalizing:           return "Wrapping up..."
        case .done(let s):          return s.summary
        case .cancelled:            return "Sync cancelled"
        case .error(let m):         return m
        }
    }
}

// MARK: - Sync Summary

struct SyncSummary: Equatable {
    var uploaded: Int = 0
    var entriesRemoved: Int = 0
    var filesRemoved: Int = 0
    var progressMerged: Int = 0
    var bookmarksMerged: Int = 0
    var highlightsMerged: Int = 0

    var hasChanges: Bool {
        uploaded > 0 || entriesRemoved > 0 || filesRemoved > 0 ||
        progressMerged > 0 || bookmarksMerged > 0 || highlightsMerged > 0
    }

    var summary: String {
        guard hasChanges else { return "Already in sync" }
        var parts: [String] = []
        if uploaded > 0          { parts.append("+\(uploaded) sent") }
        if entriesRemoved > 0    { parts.append("−\(entriesRemoved) removed") }
        if filesRemoved > 0      { parts.append("\(filesRemoved) freed") }
        if progressMerged > 0    { parts.append("\(progressMerged) progress") }
        if bookmarksMerged > 0   { parts.append("\(bookmarksMerged) bmks") }
        if highlightsMerged > 0  { parts.append("\(highlightsMerged) hls") }
        return "Sync complete · " + parts.joined(separator: " · ")
    }
}

// MARK: - Device V3 entry

/// Extra per-book info the device reports in V3 LIST responses. Used to plan
/// the reading-state sync: who do we need to query, who do we need to push to.
private struct DeviceV3Entry {
    var hasFile: Bool
    var size: Int64
    var hasProgress: Bool
    var bookmarkCount: Int
    var highlightCount: Int
    var filename: String
}

// MARK: - Reading-state sync sub-state

private enum ReadingStateSubPhase {
    case idle
    case queryingProgress
    case queryingBookmarks       // collecting BMK_V3 records until BMK_END
    case queryingHighlights      // collecting HL_V3 records until HL_END
    case pushingProgress         // awaiting PROGRESS_OK
    case awaitingBookmarkReady   // awaiting READY before streaming bmk blob
    case streamingBookmarkBlob   // pumping Data char (bookmarks)
    case awaitingBookmarkAck     // awaiting BMK_OK
    case awaitingHighlightReady  // awaiting READY before streaming hl blob
    case streamingHighlightBlob  // pumping Data char (highlights)
    case awaitingHighlightAck    // awaiting HL_OK
}

// MARK: - UI Entry

struct SyncBookEntry: Identifiable, Equatable {
    let id: UUID
    var displayTitle: String
    var fileSize: Int64
    var action: Action
    var progress: Double = 0

    enum Action: Equatable {
        case keep              // entry+file on device, no action
        case keepEntryOnly     // entry on device, file freed earlier
        case willUpload
        case uploading
        case uploaded
        case willDeleteEntry
        case deletingEntry
        case entryDeleted
        case willRemoveFile
        case removingFile
        case fileRemoved
        case foreign           // on device, not owned by this app
        case failed(String)
    }
}

// MARK: - BLE constants

private let kServiceUUID = CBUUID(string: "8b45f100-9128-4d4f-9a4f-7a0dc1b26b01")
private let kControlUUID = CBUUID(string: "8b45f101-9128-4d4f-9a4f-7a0dc1b26b01")
private let kDataUUID    = CBUUID(string: "8b45f102-9128-4d4f-9a4f-7a0dc1b26b01")
private let kStatusUUID  = CBUUID(string: "8b45f103-9128-4d4f-9a4f-7a0dc1b26b01")
private let kInfoUUID    = CBUUID(string: "8b45f104-9128-4d4f-9a4f-7a0dc1b26b01")

private let kDeviceName  = "CrossPoint AirBook"

// MARK: - SyncManager

@MainActor
@Observable
final class SyncManager: NSObject {
    var phase: SyncPhase = .idle
    var bookEntries: [SyncBookEntry] = []
    /// Device identity, populated when the BLE handshake reads the Info
    /// characteristic. Stays nil for older firmware that doesn't expose it
    /// — the UI uses that to decide between "Searching..." and "found".
    var deviceInfo: DeviceFirmwareInfo?
    /// Ring-buffer of the most recent BLE control/status lines, oldest first.
    /// Surfaced by `SyncDiagnosticsView` for in-the-wild troubleshooting.
    private(set) var traceLog: [String] = []
    private let traceCap = 80

    // BLE
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var controlChar: CBCharacteristic?
    @ObservationIgnored private var dataChar: CBCharacteristic?
    @ObservationIgnored private var statusChar: CBCharacteristic?
    @ObservationIgnored private var infoChar: CBCharacteristic?
    @ObservationIgnored private var scanTimer: Timer?
    @ObservationIgnored private var discoveryTimer: Timer?
    @ObservationIgnored private var discoveredPeripherals: [CBPeripheral] = []
    @ObservationIgnored private weak var store: BookStore?
    @ObservationIgnored private weak var readingStateStore: ReadingStateStore?
    @ObservationIgnored private var chunkSize: Int = 512

    // Negotiated protocol version. V2 path still works untouched, V3 unlocks
    // reading-state sync between LIST and the file-op plan.
    @ObservationIgnored private(set) var protocolVersion: ProtocolVersion = .v2

    // Device LIST results — V2 only fills .filePresent/.entryOnly + filenames.
    // V3 LIST also fills v3Entries with progress/bmk/highlight counts.
    @ObservationIgnored private var deviceReport: [UUID: DeviceFileState] = [:]
    @ObservationIgnored private var deviceFilenames: [UUID: String] = [:]
    @ObservationIgnored private var v3Entries: [UUID: DeviceV3Entry] = [:]

    // Operation plan (drained in this order)
    @ObservationIgnored private var deleteEntryQueue: [UUID] = []
    @ObservationIgnored private var removeFileQueue: [UUID] = []
    @ObservationIgnored private var uploadQueue: [(book: Book, data: Data)] = []

    // Execution cursors
    @ObservationIgnored private var phaseLabel: String = ""
    @ObservationIgnored private var phaseTotal: Int = 0
    @ObservationIgnored private var phaseDone: Int = 0
    @ObservationIgnored private var currentUploadOffset: Int = 0
    @ObservationIgnored private var summary = SyncSummary()

    // Overall upload progress so the SyncStatusHeader's bar reflects all
    // books, not just the one currently in flight. Set at plan time.
    @ObservationIgnored private var totalBytesPlanned: Int64 = 0
    @ObservationIgnored private var totalBytesCompleted: Int64 = 0

    // Reading-state sync (V3 only)
    @ObservationIgnored private var rsBookQueue: [UUID] = []
    @ObservationIgnored private var rsCursor: Int = 0
    @ObservationIgnored private var rsSubPhase: ReadingStateSubPhase = .idle
    /// Bookmarks streamed from the device for the current book, accumulated
    /// until BMK_END, then merged with local sidecar state.
    @ObservationIgnored private var rsIncomingBookmarks: [BookmarkRecord] = []
    /// Push blob currently in flight + cursor for chunked write.
    @ObservationIgnored private var rsPushBlob: Data = Data()
    @ObservationIgnored private var rsPushOffset: Int = 0
    @ObservationIgnored private var rsPushBookID: UUID?
    @ObservationIgnored private var rsPushBookmarkCount: Int = 0
    @ObservationIgnored private var rsPushHighlightCount: Int = 0
    @ObservationIgnored private var rsIncomingHighlights: [HighlightRecord] = []
    /// Tracks which protocol the active handshake attempt used, so an ERROR
    /// reply during V3 negotiation can transparently retry as V2.
    @ObservationIgnored private var handshakeAttempt: HandshakeAttempt = .none

    private enum HandshakeAttempt { case none, v3, v2 }

    // MARK: - Public API

    func start(store: BookStore, readingStateStore: ReadingStateStore? = nil) {
        guard !phase.isActive else { return }
        self.store = store
        self.readingStateStore = readingStateStore
        reset(toIdle: false)
        phase = .scanning
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
        armScanTimeout()
    }

    func cancel() {
        scanTimer?.invalidate(); scanTimer = nil
        if peripheral != nil { writeControl("SYNC_END") }
        phase = .cancelled
        shutdown()
    }

    func reset() {
        guard !phase.isActive else { return }
        reset(toIdle: true)
    }

    private func reset(toIdle: Bool) {
        bookEntries = []
        deviceInfo = nil
        deviceReport = [:]
        deviceFilenames = [:]
        v3Entries = [:]
        deleteEntryQueue = []
        removeFileQueue = []
        uploadQueue = []
        phaseLabel = ""
        phaseTotal = 0
        phaseDone = 0
        currentUploadOffset = 0
        totalBytesPlanned = 0
        totalBytesCompleted = 0
        summary = SyncSummary()
        discoveredPeripherals = []
        protocolVersion = .v2
        rsBookQueue = []
        rsCursor = 0
        rsSubPhase = .idle
        rsIncomingBookmarks = []
        rsPushBlob = Data()
        rsPushOffset = 0
        rsPushBookID = nil
        rsPushBookmarkCount = 0
        if toIdle { phase = .idle }
    }

    // MARK: - BLE writes

    private func writeControl(_ message: String) {
        guard let p = peripheral, let c = controlChar else { return }
        appendTrace("→ \(message)")
        p.writeValue(message.data(using: .utf8)!, for: c, type: .withResponse)
    }

    private func appendTrace(_ line: String) {
        traceLog.append(line)
        if traceLog.count > traceCap {
            traceLog.removeFirst(traceLog.count - traceCap)
        }
    }

    // MARK: - Status handler

    private func handleStatus(_ raw: String) {
        let msg = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        appendTrace("← \(msg)")

        switch phase {
        case .done, .error, .cancelled: return
        default: break
        }

        // Ignore the legacy "connected/waiting" pings — they predate the V2 flow.
        if msg == "CONNECTED" || msg == "WAITING" { return }

        // V3 handshake response: "SYNC_READY_V3:<free_kb>" (or no suffix).
        if msg.hasPrefix("SYNC_READY_V3") {
            let suffix = msg.dropFirst("SYNC_READY_V3".count)
            var freeKB = 0
            if suffix.hasPrefix(":"),
               let parsed = Int(suffix.dropFirst()) {
                freeKB = parsed
            }
            protocolVersion = .v3(freeHeapKB: freeKB)
            handshakeAttempt = .none
            phase = .listing
            writeControl("LIST_V3")
            return
        }

        if msg == "SYNC_READY_V2" {
            protocolVersion = .v2
            handshakeAttempt = .none
            phase = .listing
            writeControl("LIST_V2")
            return
        }

        if msg.hasPrefix("FILE_V3:") {
            parseFileV3(payload: String(msg.dropFirst("FILE_V3:".count)))
            return
        }

        if msg.hasPrefix("FILE_V2:") {
            parseFileV2(payload: String(msg.dropFirst("FILE_V2:".count)))
            return
        }

        if msg == "FILES_END" {
            // V3 inserts a reading-state phase before file ops; V2 goes
            // straight to the file-op plan.
            if protocolVersion.isV3 {
                startReadingStateSync()
            } else {
                buildPlanAndStart()
            }
            return
        }

        // V3 reading-state responses
        if msg.hasPrefix("PROGRESS_V3:") {
            handleProgressV3(payload: String(msg.dropFirst("PROGRESS_V3:".count)))
            return
        }
        if msg.hasPrefix("PROGRESS_OK:") {
            handleProgressOK(payload: String(msg.dropFirst("PROGRESS_OK:".count)))
            return
        }
        if msg.hasPrefix("BMK_V3:") {
            handleBookmarkRecord(payload: String(msg.dropFirst("BMK_V3:".count)))
            return
        }
        if msg.hasPrefix("BMK_END:") {
            handleBookmarkEnd(payload: String(msg.dropFirst("BMK_END:".count)))
            return
        }
        if msg.hasPrefix("BMK_OK:") {
            handleBookmarkPushAck(payload: String(msg.dropFirst("BMK_OK:".count)))
            return
        }
        if msg.hasPrefix("HL_V3:") {
            handleHighlightRecord(payload: String(msg.dropFirst("HL_V3:".count)))
            return
        }
        if msg.hasPrefix("HL_END:") {
            handleHighlightEnd(payload: String(msg.dropFirst("HL_END:".count)))
            return
        }
        if msg.hasPrefix("HL_OK:") {
            handleHighlightPushAck(payload: String(msg.dropFirst("HL_OK:".count)))
            return
        }

        if msg == "READY" {
            // Distinguish file-upload READY from bookmark/highlight-push
            // READY by the sub-phase: only the latter is streaming on the
            // Data char now.
            switch rsSubPhase {
            case .awaitingBookmarkReady:
                rsSubPhase = .streamingBookmarkBlob
                pumpReadingStateBlob()
            case .awaitingHighlightReady:
                rsSubPhase = .streamingHighlightBlob
                pumpReadingStateBlob()
            default:
                pumpUpload()
            }
            return
        }

        if msg.hasPrefix("PROGRESS:") {
            handleProgress(payload: String(msg.dropFirst("PROGRESS:".count)))
            pumpUpload()
            return
        }

        if msg.hasPrefix("DONE_V2:") {
            finishCurrentUpload(idString: String(msg.dropFirst("DONE_V2:".count)))
            return
        }

        if msg.hasPrefix("DELETED_V2:") {
            finishCurrentEntryDelete(idString: String(msg.dropFirst("DELETED_V2:".count)))
            return
        }

        if msg.hasPrefix("FILE_REMOVED:") {
            finishCurrentFileRemove(idString: String(msg.dropFirst("FILE_REMOVED:".count)))
            return
        }

        if msg == "SYNC_DONE" {
            phase = .done(summary)
            shutdown()
            return
        }

        if msg.hasPrefix("ERROR_V2:") {
            // ERROR_V2:<id>:<message>
            let payload = msg.dropFirst("ERROR_V2:".count)
            let parts = payload.split(separator: ":", maxSplits: 1)
            let id = parts.first.flatMap { UUID(uuidString: String($0)) }
            let errMsg = parts.count > 1 ? String(parts[1]) : "Device error"
            handleOpError(forID: id, message: errMsg)
            return
        }

        if msg.hasPrefix("ERROR:") {
            let body = String(msg.dropFirst("ERROR:".count))

            // V3 fallback: any error during V3 handshake means the firmware
            // doesn't speak V3 — retry with the V2 handshake so a mixed
            // rollout (old firmware + new iOS) keeps working.
            if case .handshake = phase, handshakeAttempt == .v3 {
                handshakeAttempt = .v2
                writeControl("SYNC_START_V2")
                return
            }

            // V2 also failed → firmware is too old.
            if case .handshake = phase, handshakeAttempt == .v2 {
                phase = .error("Update your CrossPoint firmware to use AirBook sync.\nReceived: \(body)")
                shutdown()
                return
            }

            handleOpError(forID: nil, message: body)
            return
        }

        // Legacy responses we don't expect but won't crash on.
        if msg == "SYNC_READY" {
            phase = .error("Old firmware detected. Update CrossPoint to use this version of AirBook.")
            shutdown()
            return
        }
    }

    private func parseFileV2(payload: String) {
        // <uuid>:<has_file 0|1>:<size>:<filename>
        let parts = payload.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              let id = UUID(uuidString: String(parts[0])),
              let hasFileFlag = Int(parts[1]),
              let size = Int64(parts[2]) else { return }

        deviceReport[id] = (hasFileFlag == 1) ? .filePresent : .entryOnly
        deviceFilenames[id] = String(parts[3])
        _ = size  // currently informational only; could be surfaced in UI later
    }

    private func handleProgress(payload: String) {
        // PROGRESS:<done>:<total> is per-book on the wire. Convert to the
        // overall counters so the header bar tracks all uploads together
        // instead of resetting between books.
        let parts = payload.split(separator: ":")
        guard parts.count == 2,
              let bookDone = Int64(parts[0]),
              let bookTotal = Int64(parts[1]),
              bookTotal > 0,
              case .executing(var step) = phase else { return }

        step.bytesTransferred = totalBytesCompleted + bookDone
        step.bytesTotal = max(totalBytesPlanned, totalBytesCompleted + bookTotal)
        phase = .executing(step)
        updateUploadingProgress(done: bookDone, total: bookTotal)
    }

    private func handleOpError(forID id: UUID?, message: String) {
        // Mark the offending op as failed and continue with the next.
        switch phase {
        case .executing(let step) where step.label.hasPrefix("Sending"):
            if let id, let idx = bookEntries.firstIndex(where: { $0.id == id }) {
                bookEntries[idx].action = .failed(message)
            }
            advanceUploadCursor()
            advance()
        case .executing(let step) where step.label.hasPrefix("Removing entries"):
            if let id, let idx = bookEntries.firstIndex(where: { $0.id == id }) {
                bookEntries[idx].action = .failed(message)
            }
            advanceDeleteCursor()
            advance()
        case .executing(let step) where step.label.hasPrefix("Freeing"):
            if let id, let idx = bookEntries.firstIndex(where: { $0.id == id }) {
                bookEntries[idx].action = .failed(message)
            }
            advanceRemoveCursor()
            advance()
        case .executing(let step) where step.label == "Syncing reading state":
            // Per-book reading-state error — skip this book and continue.
            // Don't abort the whole sync just because one book hit a
            // device-side cap during bookmark/highlight push.
            rsPushBlob = Data()
            rsPushOffset = 0
            rsPushBookID = nil
            rsPushBookmarkCount = 0
            rsPushHighlightCount = 0
            rsIncomingBookmarks = []
            rsIncomingHighlights = []
            rsSubPhase = .idle
            advanceToNextReadingStateBook()
        default:
            phase = .error(message)
            shutdown()
        }
    }

    // MARK: - Plan

    private func buildPlanAndStart() {
        guard let store else { shutdown(); return }

        // Apply the device's view of the world to the BookStore first so the
        // library cards immediately reflect what we just learned.
        store.applyDeviceReport(deviceReport)

        let liveBooksByID = Dictionary(uniqueKeysWithValues: store.books.map { ($0.id, $0) })

        // 1. Tombstones: IDs the device confirmed it has AND we previously sent
        //    AND aren't in the local library anymore.
        let appKnown = Set(store.books.map { $0.id })
        let deviceKnown = Set(deviceReport.keys)
        let tombstones = store.sentBookIDs.intersection(deviceKnown).subtracting(appKnown)
        deleteEntryQueue = Array(tombstones)

        // 2. File-removal queue (intersect with device entries that still have a file)
        removeFileQueue = store.pendingFileRemovals.filter { id in
            deviceReport[id] == .filePresent
        }

        // 3. Uploads: every local book the device doesn't have. We do NOT
        //    auto-re-send entryOnly books — the user freed that space on purpose.
        var uploads: [(book: Book, data: Data)] = []
        for book in store.books where deviceReport[book.id] == nil {
            if let data = try? store.fileData(for: book) {
                uploads.append((book, data))
            } else {
                bookEntries.append(SyncBookEntry(id: book.id,
                                                 displayTitle: book.displayTitle,
                                                 fileSize: book.fileSize,
                                                 action: .failed("Local file missing")))
            }
        }
        uploadQueue = uploads
        totalBytesPlanned = uploads.reduce(Int64(0)) { $0 + Int64($1.data.count) }
        totalBytesCompleted = 0

        // Build the visible entry list, in execution order so the UI reads
        // top-to-bottom as the sync progresses.
        var entries: [SyncBookEntry] = []

        for id in deleteEntryQueue {
            let title = deviceFilenames[id].map(stripExtension) ?? "Removed book"
            entries.append(SyncBookEntry(id: id, displayTitle: title,
                                         fileSize: 0, action: .willDeleteEntry))
        }
        for id in removeFileQueue {
            let book = liveBooksByID[id]
            let title = book?.displayTitle ?? deviceFilenames[id].map(stripExtension) ?? "Book"
            entries.append(SyncBookEntry(id: id, displayTitle: title,
                                         fileSize: book?.fileSize ?? 0, action: .willRemoveFile))
        }
        for (book, _) in uploadQueue {
            entries.append(SyncBookEntry(id: book.id, displayTitle: book.displayTitle,
                                         fileSize: book.fileSize, action: .willUpload))
        }
        // Books already in good shape (entry+file, or entry-only kept on purpose).
        for book in store.books {
            switch deviceReport[book.id] {
            case .filePresent:
                if !entries.contains(where: { $0.id == book.id }) {
                    entries.append(SyncBookEntry(id: book.id,
                                                 displayTitle: book.displayTitle,
                                                 fileSize: book.fileSize, action: .keep))
                }
            case .entryOnly:
                if !entries.contains(where: { $0.id == book.id }) {
                    entries.append(SyncBookEntry(id: book.id,
                                                 displayTitle: book.displayTitle,
                                                 fileSize: book.fileSize, action: .keepEntryOnly))
                }
            default: break
            }
        }
        // Foreign entries on the device (loaded outside this app).
        for (id, _) in deviceReport where !store.sentBookIDs.contains(id) {
            if !entries.contains(where: { $0.id == id }) {
                let title = deviceFilenames[id].map(stripExtension) ?? "Book"
                entries.append(SyncBookEntry(id: id, displayTitle: title,
                                             fileSize: 0, action: .foreign))
            }
        }
        bookEntries = entries

        advance()
    }

    // MARK: - Execution

    private func advance() {
        if !deleteEntryQueue.isEmpty {
            performNextDeleteEntry()
            return
        }
        if !removeFileQueue.isEmpty {
            performNextRemoveFile()
            return
        }
        if !uploadQueue.isEmpty {
            performNextUpload()
            return
        }
        // Done — wrap up.
        phase = .finalizing
        writeControl("SYNC_END")
        // The device responds with SYNC_DONE; handleStatus moves us to .done.
    }

    private func performNextDeleteEntry() {
        let id = deleteEntryQueue[0]
        if phaseLabel != "Removing entries" {
            phaseLabel = "Removing entries"
            phaseTotal = deleteEntryQueue.count
            phaseDone = 0
        }
        phase = .executing(.init(label: phaseLabel,
                                  current: phaseDone + 1,
                                  total: phaseTotal))
        markEntry(id: id, action: .deletingEntry)
        writeControl("DELETE_ENTRY:\(id.uuidString)")
    }

    private func performNextRemoveFile() {
        let id = removeFileQueue[0]
        if phaseLabel != "Freeing space" {
            phaseLabel = "Freeing space"
            phaseTotal = removeFileQueue.count
            phaseDone = 0
        }
        phase = .executing(.init(label: phaseLabel,
                                  current: phaseDone + 1,
                                  total: phaseTotal))
        markEntry(id: id, action: .removingFile)
        writeControl("DELETE_FILE:\(id.uuidString)")
    }

    private func performNextUpload() {
        let upload = uploadQueue[0]
        let book = upload.book
        if phaseLabel != "Sending books" {
            phaseLabel = "Sending books"
            phaseTotal = uploadQueue.count
            phaseDone = 0
        }
        currentUploadOffset = 0
        // bytesTransferred/bytesTotal now drive the overall progress bar
        // (sum across all queued uploads), not the per-book progress. The
        // "1/N" counter still tracks individual books via current/total.
        phase = .executing(.init(label: phaseLabel,
                                  current: phaseDone + 1,
                                  total: phaseTotal,
                                  bytesTransferred: totalBytesCompleted,
                                  bytesTotal: totalBytesPlanned))
        markEntry(id: book.id, action: .uploading)
        writeControl("START_V2:\(book.id.uuidString):\(upload.data.count):\(book.filename)")
        // Device responds with READY; pumpUpload starts shipping bytes.
    }

    private func pumpUpload() {
        guard !uploadQueue.isEmpty,
              let p = peripheral,
              let dc = dataChar else { return }
        let data = uploadQueue[0].data
        while currentUploadOffset < data.count && p.canSendWriteWithoutResponse {
            let end = min(currentUploadOffset + chunkSize, data.count)
            p.writeValue(data.subdata(in: currentUploadOffset..<end),
                         for: dc, type: .withoutResponse)
            currentUploadOffset = end
            updateUploadingProgress(done: Int64(end), total: Int64(data.count))
        }
    }

    private func updateUploadingProgress(done: Int64, total: Int64) {
        // `done`/`total` here are per-book (used by the row's progress
        // ring). The header bar reads bytesTransferred/bytesTotal from
        // the StepInfo, which already holds the overall counters set
        // upstream in handleProgress.
        guard !uploadQueue.isEmpty, total > 0 else { return }
        let book = uploadQueue[0].book
        let p = Double(done) / Double(total)
        if let idx = bookEntries.firstIndex(where: { $0.id == book.id }) {
            bookEntries[idx].progress = p
        }
        if case .executing(var step) = phase {
            step.bytesTransferred = totalBytesCompleted + done
            step.bytesTotal = max(totalBytesPlanned, totalBytesCompleted + total)
            phase = .executing(step)
        }
    }

    // MARK: - Op completion

    private func finishCurrentUpload(idString: String) {
        guard let id = UUID(uuidString: idString),
              !uploadQueue.isEmpty,
              uploadQueue[0].book.id == id else { return }
        let book = uploadQueue[0].book
        store?.markUploaded(book)
        markEntry(id: id, action: .uploaded)
        summary.uploaded += 1
        // Roll the just-finished book's full byte count into the overall
        // total so the header bar doesn't snap backwards when the next
        // upload starts.
        totalBytesCompleted += Int64(uploadQueue[0].data.count)
        advanceUploadCursor()
        advance()
    }

    private func finishCurrentEntryDelete(idString: String) {
        guard let id = UUID(uuidString: idString),
              !deleteEntryQueue.isEmpty,
              deleteEntryQueue[0] == id else { return }
        store?.markEntryRemovedFromDevice(bookID: id)
        markEntry(id: id, action: .entryDeleted)
        summary.entriesRemoved += 1
        advanceDeleteCursor()
        advance()
    }

    private func finishCurrentFileRemove(idString: String) {
        guard let id = UUID(uuidString: idString),
              !removeFileQueue.isEmpty,
              removeFileQueue[0] == id else { return }
        store?.markFileRemovedFromDevice(bookID: id)
        markEntry(id: id, action: .fileRemoved)
        summary.filesRemoved += 1
        advanceRemoveCursor()
        advance()
    }

    private func advanceUploadCursor() {
        guard !uploadQueue.isEmpty else { return }
        uploadQueue.removeFirst()
        phaseDone += 1
        currentUploadOffset = 0
    }

    private func advanceDeleteCursor() {
        guard !deleteEntryQueue.isEmpty else { return }
        deleteEntryQueue.removeFirst()
        phaseDone += 1
    }

    private func advanceRemoveCursor() {
        guard !removeFileQueue.isEmpty else { return }
        removeFileQueue.removeFirst()
        phaseDone += 1
    }

    private func markEntry(id: UUID, action: SyncBookEntry.Action) {
        if let idx = bookEntries.firstIndex(where: { $0.id == id }) {
            bookEntries[idx].action = action
            if case .uploading = action {} else { bookEntries[idx].progress = 0 }
        }
    }

    private func stripExtension(_ s: String) -> String {
        var name = (s as NSString).deletingPathExtension
        name = name.replacingOccurrences(of: "_", with: " ")
        name = name.replacingOccurrences(of: "-", with: " ")
        return name
    }

    // MARK: - Protocol V3 — LIST parsing

    private func parseFileV3(payload: String) {
        // <uuid>:<has_file 0|1>:<size>:<has_progress 0|1>:<bmk>:<hl>:<filename>
        let parts = payload.split(separator: ":", maxSplits: 6, omittingEmptySubsequences: false)
        guard parts.count == 7,
              let id = UUID(uuidString: String(parts[0])),
              let hasFileFlag = Int(parts[1]),
              let size = Int64(parts[2]),
              let hasProgressFlag = Int(parts[3]),
              let bmkCount = Int(parts[4]),
              let hlCount = Int(parts[5]) else { return }
        let filename = String(parts[6])
        deviceReport[id] = (hasFileFlag == 1) ? .filePresent : .entryOnly
        deviceFilenames[id] = filename
        v3Entries[id] = DeviceV3Entry(
            hasFile: hasFileFlag == 1,
            size: size,
            hasProgress: hasProgressFlag == 1,
            bookmarkCount: bmkCount,
            highlightCount: hlCount,
            filename: filename)
    }

    // MARK: - Protocol V3 — reading-state orchestration

    private func startReadingStateSync() {
        guard let store else { shutdown(); return }
        store.applyDeviceReport(deviceReport)

        // Books to walk: anything the device has data for, plus anything iOS
        // has local data for. Union, dedup.
        var candidates: Set<UUID> = []
        for (id, entry) in v3Entries {
            if entry.hasProgress || entry.bookmarkCount > 0 || entry.highlightCount > 0 {
                candidates.insert(id)
            }
        }
        if let rs = readingStateStore {
            for book in store.books {
                let state = rs.state(for: book.id)
                if !state.dirtyFlags.isEmpty || !state.bookmarks.isEmpty || state.progress != nil {
                    candidates.insert(book.id)
                }
            }
        }

        rsBookQueue = Array(candidates)
        rsCursor = 0
        rsSubPhase = .idle

        if rsBookQueue.isEmpty {
            buildPlanAndStart()
            return
        }

        phaseLabel = "Syncing reading state"
        phase = .executing(.init(label: phaseLabel,
                                  current: 1, total: rsBookQueue.count))
        advanceReadingState()
    }

    private func advanceReadingState() {
        guard rsCursor < rsBookQueue.count else {
            // Reading state done — proceed with file ops.
            buildPlanAndStart()
            return
        }

        let bookID = rsBookQueue[rsCursor]
        phase = .executing(.init(label: phaseLabel,
                                  current: rsCursor + 1, total: rsBookQueue.count))
        rsSubPhase = .queryingProgress
        rsIncomingBookmarks = []
        writeControl("QUERY_PROGRESS:\(bookID.uuidString)")
    }

    private func advanceToNextReadingStateBook() {
        rsCursor += 1
        advanceReadingState()
    }

    // MARK: - Protocol V3 — progress

    private func handleProgressV3(payload: String) {
        // <uuid>:NONE  OR  <uuid>:<spine>:<page>:<count>:<percent>:<updated_ms>
        let parts = payload.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard let first = parts.first,
              let id = UUID(uuidString: String(first)) else {
            advanceToNextReadingStateBook()
            return
        }

        if parts.count >= 2 && parts[1] == "NONE" {
            // No device progress. If local has one, push it.
            if let rs = readingStateStore,
               let progress = rs.state(for: id).progress {
                sendPushProgress(bookID: id, progress: progress)
                return
            }
            queryBookmarksForCurrentBook(id)
            return
        }

        guard parts.count == 6,
              let spine = UInt16(parts[1]),
              let page = UInt16(parts[2]),
              let count = UInt16(parts[3]),
              let percentX = UInt32(parts[4]),
              let updatedMs = UInt64(parts[5]) else {
            queryBookmarksForCurrentBook(id)
            return
        }

        let deviceUpdatedAt = Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000)
        if let rs = readingStateStore {
            var state = rs.state(for: id)
            let localUpdated = state.progress?.updatedAt ?? .distantPast

            if deviceUpdatedAt > localUpdated {
                state.progress = ProgressMark(
                    spineIndex: spine,
                    pageNumber: page,
                    pageCount: count,
                    percentage: Float(percentX) / 10000.0,
                    updatedAt: deviceUpdatedAt)
                var flags = state.dirtyFlags
                flags.remove(.progress)
                state.dirtyFlags = flags
                rs.update(state)
                summary.progressMerged += 1
                queryBookmarksForCurrentBook(id)
                return
            } else if let localProgress = state.progress, localUpdated > deviceUpdatedAt {
                sendPushProgress(bookID: id, progress: localProgress)
                return
            }
        }

        queryBookmarksForCurrentBook(id)
    }

    private func sendPushProgress(bookID: UUID, progress: ProgressMark) {
        rsSubPhase = .pushingProgress
        let pctx = max(0, min(10000, Int(progress.percentage * 10000)))
        let ms = Int(progress.updatedAt.timeIntervalSince1970 * 1000)
        writeControl("PUSH_PROGRESS:\(bookID.uuidString):\(progress.spineIndex):\(progress.pageNumber):\(progress.pageCount):\(pctx):\(ms)")
    }

    private func handleProgressOK(payload: String) {
        // <uuid>
        let id = payload.split(separator: ":").first
            .flatMap { UUID(uuidString: String($0)) }
        if let id, let rs = readingStateStore {
            var state = rs.state(for: id)
            var flags = state.dirtyFlags
            flags.remove(.progress)
            state.dirtyFlags = flags
            rs.update(state)
            summary.progressMerged += 1
            queryBookmarksForCurrentBook(id)
        } else {
            advanceToNextReadingStateBook()
        }
    }

    private func queryBookmarksForCurrentBook(_ bookID: UUID) {
        let deviceCount = v3Entries[bookID]?.bookmarkCount ?? 0
        let localCount = readingStateStore?.state(for: bookID).bookmarks.count ?? 0
        let localDirty = readingStateStore?.state(for: bookID).dirtyFlags.contains(.bookmarks) ?? false

        if deviceCount == 0 && localCount == 0 {
            queryHighlightsForCurrentBook(bookID)
            return
        }

        if deviceCount == 0 {
            // Device empty, local has bookmarks (and possibly dirty) → push.
            if let rs = readingStateStore, localDirty || localCount > 0 {
                pushBookmarks(bookID: bookID, bookmarks: rs.state(for: bookID).bookmarks)
            } else {
                queryHighlightsForCurrentBook(bookID)
            }
            return
        }

        rsSubPhase = .queryingBookmarks
        rsIncomingBookmarks = []
        writeControl("QUERY_BOOKMARKS:\(bookID.uuidString)")
    }

    private func queryHighlightsForCurrentBook(_ bookID: UUID) {
        let deviceCount = v3Entries[bookID]?.highlightCount ?? 0
        let localCount = readingStateStore?.state(for: bookID).highlights.count ?? 0
        let localDirty = readingStateStore?.state(for: bookID).dirtyFlags.contains(.highlights) ?? false

        if deviceCount == 0 && localCount == 0 {
            advanceToNextReadingStateBook()
            return
        }

        if deviceCount == 0 {
            if let rs = readingStateStore, localDirty || localCount > 0 {
                pushHighlights(bookID: bookID, highlights: rs.state(for: bookID).highlights)
            } else {
                advanceToNextReadingStateBook()
            }
            return
        }

        rsSubPhase = .queryingHighlights
        rsIncomingHighlights = []
        writeControl("QUERY_HIGHLIGHTS:\(bookID.uuidString)")
    }

    // MARK: - Protocol V3 — bookmarks (pull)

    private func handleBookmarkRecord(payload: String) {
        // <book_uuid>:<idx>:<bmk_id>:<percent>:<spine>:<count>:<progress>:<xpath_b64>:<summary_b64>
        let parts = payload.split(separator: ":", maxSplits: 8, omittingEmptySubsequences: false)
        guard parts.count == 9,
              let bmkID = UUID(uuidString: String(parts[2])),
              let percent = UInt32(parts[3]),
              let spine = UInt16(parts[4]),
              let count = UInt16(parts[5]),
              let progress = UInt16(parts[6]) else {
            return
        }
        let xpath = Data(base64Encoded: String(parts[7]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let summary = Data(base64Encoded: String(parts[8]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let now = Date()
        rsIncomingBookmarks.append(BookmarkRecord(
            id: bmkID,
            xpath: xpath,
            summary: summary,
            percentage: Float(percent) / 10000.0,
            spineIndex: spine,
            chapterPageCount: count,
            chapterProgress: progress,
            createdAt: now,
            updatedAt: now,
            deviceOriginated: true))
    }

    private func handleBookmarkEnd(payload: String) {
        // <book_uuid>:<total>
        let parts = payload.split(separator: ":", maxSplits: 1)
        guard let id = parts.first.flatMap({ UUID(uuidString: String($0)) }),
              let rs = readingStateStore else {
            advanceToNextReadingStateBook()
            return
        }

        var state = rs.state(for: id)
        let merged = mergeBookmarks(local: state.bookmarks, device: rsIncomingBookmarks)

        let deviceIDs = Set(rsIncomingBookmarks.map(\.id))
        let mergedIDs = Set(merged.map(\.id))
        let localIDs = Set(state.bookmarks.map(\.id))
        let stateChanged = (mergedIDs != localIDs)
        let needsPush = (deviceIDs != mergedIDs) || state.dirtyFlags.contains(.bookmarks)

        if stateChanged {
            summary.bookmarksMerged += 1
        }
        state.bookmarks = merged
        var flags = state.dirtyFlags
        flags.remove(.bookmarks)
        state.dirtyFlags = flags
        rs.update(state)

        if needsPush {
            pushBookmarks(bookID: id, bookmarks: merged)
        } else {
            queryHighlightsForCurrentBook(id)
        }
    }

    private func mergeBookmarks(local: [BookmarkRecord],
                                device: [BookmarkRecord]) -> [BookmarkRecord] {
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        var merged: [BookmarkRecord] = []
        var seen: Set<UUID> = []
        for record in device {
            seen.insert(record.id)
            merged.append(localByID[record.id] ?? record)
        }
        for record in local where !seen.contains(record.id) {
            merged.append(record)
        }
        return merged
    }

    // MARK: - Protocol V3 — bookmarks (push)

    private func pushBookmarks(bookID: UUID, bookmarks: [BookmarkRecord]) {
        let capped = Array(bookmarks.prefix(Int(UInt16.max)))
        rsPushBlob = encodeBookmarksBlob(capped)
        rsPushOffset = 0
        rsPushBookID = bookID
        rsPushBookmarkCount = capped.count
        rsSubPhase = .awaitingBookmarkReady
        writeControl("PUSH_BOOKMARKS:\(bookID.uuidString):\(capped.count)")
    }

    private func encodeBookmarksBlob(_ bookmarks: [BookmarkRecord]) -> Data {
        var blob = Data()
        appendLE16(UInt16(bookmarks.count), to: &blob)

        for b in bookmarks {
            var record = Data()
            var uuidBytes = b.id.uuid
            record.append(withUnsafeBytes(of: &uuidBytes) { Data($0) })
            appendLE16(b.spineIndex, to: &record)
            appendLE16(b.chapterPageCount, to: &record)
            appendLE16(b.chapterProgress, to: &record)
            appendLE32(UInt32(max(0, min(10000, Int(b.percentage * 10000)))), to: &record)
            appendLE64(UInt64(b.createdAt.timeIntervalSince1970 * 1000), to: &record)

            let xpath = utf8Capped(b.xpath, maxBytes: 240)
            appendLE16(UInt16(xpath.count), to: &record)
            record.append(xpath)
            let summary = utf8Capped(b.summary, maxBytes: 240)
            appendLE16(UInt16(summary.count), to: &record)
            record.append(summary)

            appendLE16(UInt16(record.count), to: &blob)
            blob.append(record)
        }
        return blob
    }

    private func pumpReadingStateBlob() {
        guard rsSubPhase == .streamingBookmarkBlob,
              let p = peripheral, let dc = dataChar else { return }
        while rsPushOffset < rsPushBlob.count && p.canSendWriteWithoutResponse {
            let end = min(rsPushOffset + chunkSize, rsPushBlob.count)
            p.writeValue(rsPushBlob.subdata(in: rsPushOffset..<end),
                         for: dc, type: .withoutResponse)
            rsPushOffset = end
        }
        if rsPushOffset >= rsPushBlob.count {
            rsSubPhase = .awaitingBookmarkAck
        }
    }

    private func handleBookmarkPushAck(payload: String) {
        let prevBookID = rsPushBookID
        rsPushBlob = Data()
        rsPushOffset = 0
        rsPushBookID = nil
        rsPushBookmarkCount = 0
        rsSubPhase = .idle
        if let id = prevBookID {
            queryHighlightsForCurrentBook(id)
        } else if rsCursor < rsBookQueue.count {
            queryHighlightsForCurrentBook(rsBookQueue[rsCursor])
        } else {
            advanceToNextReadingStateBook()
        }
    }

    // MARK: - Protocol V3 — highlights

    private func handleHighlightRecord(payload: String) {
        // <book_uuid>:<idx>:<hl_id>:<xstart_b64>:<offset_start>:<xend_b64>:<offset_end>:<color>:<note_b64>
        let parts = payload.split(separator: ":", maxSplits: 8, omittingEmptySubsequences: false)
        guard parts.count == 9,
              let hlID = UUID(uuidString: String(parts[2])),
              let offsetStart = UInt32(parts[4]),
              let offsetEnd = UInt32(parts[6]),
              let colorRaw = UInt8(parts[7]) else {
            return
        }
        let xpathStart = Data(base64Encoded: String(parts[3]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let xpathEnd = Data(base64Encoded: String(parts[5]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let note = Data(base64Encoded: String(parts[8]))
            .flatMap { String(data: $0, encoding: .utf8) }
        let now = Date()
        rsIncomingHighlights.append(HighlightRecord(
            id: hlID,
            xpathStart: xpathStart,
            offsetStart: offsetStart,
            xpathEnd: xpathEnd,
            offsetEnd: offsetEnd,
            colorTag: HighlightColor(rawValue: colorRaw) ?? .yellow,
            note: (note?.isEmpty ?? true) ? nil : note,
            snippet: "",
            createdAt: now,
            updatedAt: now))
    }

    private func handleHighlightEnd(payload: String) {
        // <book_uuid>:<total>
        let parts = payload.split(separator: ":", maxSplits: 1)
        guard let id = parts.first.flatMap({ UUID(uuidString: String($0)) }),
              let rs = readingStateStore else {
            advanceToNextReadingStateBook()
            return
        }

        var state = rs.state(for: id)
        let merged = mergeHighlights(local: state.highlights, device: rsIncomingHighlights)
        let deviceIDs = Set(rsIncomingHighlights.map(\.id))
        let mergedIDs = Set(merged.map(\.id))
        let localIDs = Set(state.highlights.map(\.id))
        let stateChanged = (mergedIDs != localIDs)
        let needsPush = (deviceIDs != mergedIDs) || state.dirtyFlags.contains(.highlights)

        if stateChanged {
            summary.highlightsMerged += 1
        }
        state.highlights = merged
        var flags = state.dirtyFlags
        flags.remove(.highlights)
        state.dirtyFlags = flags
        rs.update(state)

        if needsPush {
            pushHighlights(bookID: id, highlights: merged)
        } else {
            advanceToNextReadingStateBook()
        }
    }

    private func mergeHighlights(local: [HighlightRecord],
                                 device: [HighlightRecord]) -> [HighlightRecord] {
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        var merged: [HighlightRecord] = []
        var seen: Set<UUID> = []
        for record in device {
            seen.insert(record.id)
            merged.append(localByID[record.id] ?? record)
        }
        for record in local where !seen.contains(record.id) {
            merged.append(record)
        }
        return merged
    }

    private func pushHighlights(bookID: UUID, highlights: [HighlightRecord]) {
        let capped = Array(highlights.prefix(Int(UInt16.max)))
        rsPushBlob = encodeHighlightsBlob(capped)
        rsPushOffset = 0
        rsPushBookID = bookID
        rsPushHighlightCount = capped.count
        rsSubPhase = .awaitingHighlightReady
        writeControl("PUSH_HIGHLIGHTS:\(bookID.uuidString):\(capped.count)")
    }

    private func encodeHighlightsBlob(_ highlights: [HighlightRecord]) -> Data {
        var blob = Data()
        appendLE16(UInt16(highlights.count), to: &blob)

        for h in highlights {
            var record = Data()
            var uuidBytes = h.id.uuid
            record.append(withUnsafeBytes(of: &uuidBytes) { Data($0) })

            let xs = utf8Capped(h.xpathStart, maxBytes: 240)
            appendLE16(UInt16(xs.count), to: &record)
            record.append(xs)
            appendLE32(h.offsetStart, to: &record)

            let xe = utf8Capped(h.xpathEnd, maxBytes: 240)
            appendLE16(UInt16(xe.count), to: &record)
            record.append(xe)
            appendLE32(h.offsetEnd, to: &record)

            record.append(h.colorTag.rawValue)
            let hasNote: UInt8 = (h.note?.isEmpty == false) ? 0x01 : 0x00
            record.append(hasNote)
            record.append(0)  // reserved
            record.append(0)  // reserved

            appendLE64(UInt64(h.createdAt.timeIntervalSince1970 * 1000), to: &record)
            appendLE64(UInt64(h.updatedAt.timeIntervalSince1970 * 1000), to: &record)

            if let note = h.note, !note.isEmpty {
                let nb = utf8Capped(note, maxBytes: 120)
                appendLE16(UInt16(nb.count), to: &record)
                record.append(nb)
            }

            appendLE16(UInt16(record.count), to: &blob)
            blob.append(record)
        }
        return blob
    }

    private func handleHighlightPushAck(payload: String) {
        rsPushBlob = Data()
        rsPushOffset = 0
        rsPushBookID = nil
        rsPushHighlightCount = 0
        rsSubPhase = .idle
        advanceToNextReadingStateBook()
    }

    // MARK: - Binary helpers

    private func appendLE16(_ v: UInt16, to data: inout Data) {
        var le = v.littleEndian
        data.append(Data(bytes: &le, count: 2))
    }
    private func appendLE32(_ v: UInt32, to data: inout Data) {
        var le = v.littleEndian
        data.append(Data(bytes: &le, count: 4))
    }
    private func appendLE64(_ v: UInt64, to data: inout Data) {
        var le = v.littleEndian
        data.append(Data(bytes: &le, count: 8))
    }
    /// Truncate a String to at most `maxBytes` valid UTF-8 bytes, peeling
    /// continuation bytes back so the device side can't choke on a half
    /// codepoint.
    private func utf8Capped(_ s: String, maxBytes: Int) -> Data {
        var data = Data(s.utf8)
        guard data.count > maxBytes else { return data }
        data = data.prefix(maxBytes)
        while let last = data.last, (last & 0xC0) == 0x80 {
            data = data.dropLast()
        }
        if let last = data.last, last >= 0x80 {
            data = data.dropLast()
        }
        return data
    }

    // MARK: - BLE plumbing

    private func armScanTimeout() {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self, case .scanning = self.phase else { return }
            self.phase = .error("CrossPoint not found.\nMake sure it's on the Sync with AirBook screen.")
            self.shutdown()
        }
    }

    private func shutdown() {
        scanTimer?.invalidate(); scanTimer = nil
        discoveryTimer?.invalidate(); discoveryTimer = nil
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.delegate = nil
        central = nil
        peripheral = nil
        controlChar = nil
        dataChar = nil
        statusChar = nil
        infoChar = nil
    }
}

// MARK: - CBCentralManagerDelegate

extension SyncManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: nil, options: nil)
        case .poweredOff:
            phase = .error("Please enable Bluetooth to sync.")
            shutdown()
        case .unauthorized:
            phase = .error("Bluetooth access denied. Enable it in Settings > Privacy.")
            shutdown()
        case .unsupported:
            phase = .error("Bluetooth is not available on this device.")
            shutdown()
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.name == kDeviceName else { return }
        if discoveredPeripherals.isEmpty {
            scanTimer?.invalidate(); scanTimer = nil
            discoveryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.finishDiscovery()
            }
        }
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
        }
    }

    private func finishDiscovery() {
        central?.stopScan()
        if discoveredPeripherals.count > 1 {
            phase = .error("Multiple CrossPoint devices found nearby.\nTurn off Bluetooth Receive on the others, or move further away.")
            shutdown()
            return
        }
        guard let device = discoveredPeripherals.first else { shutdown(); return }
        self.peripheral = device
        phase = .connecting
        central?.connect(device, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([kServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        phase = .error(error?.localizedDescription ?? "Failed to connect to CrossPoint.")
        shutdown()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard phase.isActive else { return }
        phase = .error("CrossPoint disconnected unexpectedly.")
    }
}

// MARK: - CBPeripheralDelegate

extension SyncManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == kServiceUUID }) else {
            phase = .error("CrossPoint service not found.")
            shutdown()
            return
        }
        peripheral.discoverCharacteristics(
            [kControlUUID, kDataUUID, kStatusUUID, kInfoUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            phase = .error("Failed to discover BLE characteristics.")
            shutdown()
            return
        }
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case kControlUUID: controlChar = char
            case kDataUUID:    dataChar = char
            case kStatusUUID:  statusChar = char
            case kInfoUUID:    infoChar = char
            default: break
            }
        }
        guard controlChar != nil, dataChar != nil, let sc = statusChar else {
            phase = .error("Missing required BLE characteristics.")
            shutdown()
            return
        }
        chunkSize = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        peripheral.setNotifyValue(true, for: sc)
        // Kick off the Info read in parallel with the V3 handshake. The
        // device info shows up in the Device panel as soon as the read
        // lands; if the firmware predates Info char support, infoChar
        // stays nil and we just don't expose a version. Either way the
        // sync handshake proceeds.
        if let ic = infoChar {
            peripheral.readValue(for: ic)
        }
        phase = .handshake
        // Try V3 first. On ERROR during handshake we fall back to V2
        // transparently — see handleStatus's ERROR: branch.
        handshakeAttempt = .v3
        writeControl("SYNC_START_V3")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == kInfoUUID {
            if let data = characteristic.value,
               let info = DeviceFirmwareInfo.parse(data) {
                deviceInfo = info
                appendTrace("info: fw=\(info.version) caps=\(info.capabilities.sorted().joined(separator: ","))")
            }
            return
        }
        guard characteristic.uuid == kStatusUUID,
              let data = characteristic.value,
              let msg = String(data: data, encoding: .utf8) else { return }
        handleStatus(msg)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            phase = .error("Write error: \(error.localizedDescription)")
            shutdown()
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if rsSubPhase == .streamingBookmarkBlob || rsSubPhase == .streamingHighlightBlob {
            pumpReadingStateBlob()
            return
        }
        if case .executing(let step) = phase, step.label.hasPrefix("Sending") {
            pumpUpload()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {}
}
