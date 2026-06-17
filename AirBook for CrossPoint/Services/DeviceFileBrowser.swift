import CoreBluetooth
import Foundation

// MARK: - Models

struct DeviceFileEntry: Identifiable, Equatable, Hashable {
    let name: String        // basename — no path
    let size: Int64         // 0 for directories
    let isDirectory: Bool
    /// Path relative to /AirBook (the firmware's root). `subfolder/book.epub`
    /// for a file inside one subfolder, just `name` for /AirBook root.
    let relativePath: String
    var id: String { relativePath.isEmpty ? name : relativePath }
}

enum DeviceFileBrowserPhase: Equatable {
    case idle
    case scanning
    case connecting
    case discovering
    case listing(path: String)   // path relative to /AirBook (empty = root)
    case ready(path: String, entries: [DeviceFileEntry])
    case downloading(DeviceFileEntry, bytesDone: Int64, bytesTotal: Int64)
    case downloaded(DeviceFileEntry, URL)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .idle, .failed, .downloaded, .ready: return false
        default: return true
        }
    }

    var currentPath: String {
        switch self {
        case .listing(let p), .ready(let p, _): return p
        case .downloading(let e, _, _), .downloaded(let e, _):
            // Drop the filename from the relative path to get parent.
            return parentOf(e.relativePath)
        default: return ""
        }
    }

    private func parentOf(_ rel: String) -> String {
        if let slash = rel.lastIndex(of: "/") {
            return String(rel[..<slash])
        }
        return ""
    }
}

// MARK: - BLE constants
//
// Mirror the device's UUID layout. FILE_OUT lives on 8b45f105 and is the
// device → iOS file data stream.

private let kServiceUUID = CBUUID(string: "8b45f100-9128-4d4f-9a4f-7a0dc1b26b01")
private let kControlUUID = CBUUID(string: "8b45f101-9128-4d4f-9a4f-7a0dc1b26b01")
private let kStatusUUID  = CBUUID(string: "8b45f103-9128-4d4f-9a4f-7a0dc1b26b01")
private let kInfoUUID    = CBUUID(string: "8b45f104-9128-4d4f-9a4f-7a0dc1b26b01")
private let kFileOutUUID = CBUUID(string: "8b45f105-9128-4d4f-9a4f-7a0dc1b26b01")
private let kDeviceName  = "CrossPoint AirBook"

// MARK: - Manager

@MainActor
@Observable
final class DeviceFileBrowser: NSObject {
    private(set) var phase: DeviceFileBrowserPhase = .idle
    private(set) var deviceInfo: DeviceFirmwareInfo?
    private(set) var traceLog: [String] = []

    // BLE
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var controlChar: CBCharacteristic?
    @ObservationIgnored private var statusChar: CBCharacteristic?
    @ObservationIgnored private var infoChar: CBCharacteristic?
    @ObservationIgnored private var fileOutChar: CBCharacteristic?
    @ObservationIgnored private var scanTimer: Timer?
    @ObservationIgnored private var discoveryTimer: Timer?
    @ObservationIgnored private var discoveredPeripherals: [CBPeripheral] = []

    // Listing accumulation
    @ObservationIgnored private var pendingEntries: [DeviceFileEntry] = []
    @ObservationIgnored private var pendingPath: String = ""

    // Active download
    @ObservationIgnored private var downloadEntry: DeviceFileEntry?
    @ObservationIgnored private var downloadBuffer = Data()
    @ObservationIgnored private var downloadExpected: Int64 = 0

    private let traceCap = 80

    // MARK: - Public API

    func start() {
        guard !phase.isActive else { return }
        reset()
        phase = .scanning
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if case .scanning = self.phase {
                    self.phase = .failed("CrossPoint not found")
                    self.shutdown()
                }
            }
        }
    }

    /// Navigate into a subfolder (already-connected session). The browser
    /// fires a fresh BROWSE_LS for the new path and rebuilds the listing.
    func navigate(into folder: DeviceFileEntry) {
        guard folder.isDirectory else { return }
        loadDirectory(folder.relativePath)
    }

    /// Pop up to the parent directory. No-op at root.
    func navigateUp() {
        let cur = phase.currentPath
        if cur.isEmpty { return }
        if let slash = cur.lastIndex(of: "/") {
            loadDirectory(String(cur[..<slash]))
        } else {
            loadDirectory("")
        }
    }

    private func loadDirectory(_ relativePath: String) {
        guard peripheral != nil else { return }
        pendingEntries = []
        pendingPath = relativePath
        phase = .listing(path: relativePath)
        writeControl("BROWSE_LS:\(relativePath)")
    }

    func download(_ entry: DeviceFileEntry) {
        guard case .ready = phase, !entry.isDirectory else { return }
        downloadEntry = entry
        downloadBuffer = Data()
        downloadBuffer.reserveCapacity(Int(entry.size))
        downloadExpected = entry.size
        phase = .downloading(entry, bytesDone: 0, bytesTotal: entry.size)
        writeControl("BROWSE_READ:\(entry.relativePath)")
    }

    func cancelDownload() {
        if case .downloading = phase {
            writeControl("BROWSE_CANCEL")
            downloadEntry = nil
            downloadBuffer = Data()
            // Drop back to the listing the user came from.
            phase = .ready(path: pendingPath, entries: pendingEntries)
        }
    }

    func close() {
        shutdown()
        phase = .idle
    }

    // MARK: - Helpers

    private func reset() {
        scanTimer?.invalidate(); scanTimer = nil
        discoveryTimer?.invalidate(); discoveryTimer = nil
        discoveredPeripherals = []
        pendingEntries = []
        pendingPath = ""
        downloadEntry = nil
        downloadBuffer = Data()
        downloadExpected = 0
        deviceInfo = nil
        traceLog = []
    }

    private func appendTrace(_ line: String) {
        traceLog.append(line)
        if traceLog.count > traceCap {
            traceLog.removeFirst(traceLog.count - traceCap)
        }
    }

    private func writeControl(_ message: String) {
        guard let p = peripheral, let c = controlChar else { return }
        appendTrace("→ \(message)")
        p.writeValue(message.data(using: .utf8)!, for: c, type: .withResponse)
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
        statusChar = nil
        infoChar = nil
        fileOutChar = nil
    }

    // MARK: - Status handler (textual notifications)

    private func handleStatus(_ raw: String) {
        let msg = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        appendTrace("← \(msg)")

        if msg.hasPrefix("BROWSE_ENTRY:") {
            parseBrowseEntry(payload: String(msg.dropFirst("BROWSE_ENTRY:".count)))
            return
        }
        if msg == "BROWSE_LS_END" {
            // Folders first, then files — easier to scan, matches how
            // most file pickers sort.
            let sorted = pendingEntries.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            phase = .ready(path: pendingPath, entries: sorted)
            return
        }
        if msg.hasPrefix("BROWSE_READ_READY:") {
            let size = Int64(msg.dropFirst("BROWSE_READ_READY:".count)) ?? 0
            downloadExpected = size
            if case .downloading(let entry, _, _) = phase {
                phase = .downloading(entry, bytesDone: 0, bytesTotal: size)
            }
            return
        }
        if msg.hasPrefix("BROWSE_READ_PROGRESS:") {
            let payload = String(msg.dropFirst("BROWSE_READ_PROGRESS:".count))
            let parts = payload.split(separator: ":")
            if parts.count == 2,
               let done = Int64(parts[0]),
               let total = Int64(parts[1]),
               case .downloading(let entry, _, _) = phase {
                phase = .downloading(entry, bytesDone: done, bytesTotal: total)
            }
            return
        }
        if msg == "BROWSE_READ_DONE" {
            finishDownload()
            return
        }
        if msg.hasPrefix("BROWSE_ERROR:") {
            let body = String(msg.dropFirst("BROWSE_ERROR:".count))
            phase = .failed(body.isEmpty ? "Device returned an error" : body)
            shutdown()
            return
        }
        // Anything else (CONNECTED / WAITING / ERROR:..) is ignored — the
        // device may still chatter from a previous session.
    }

    private func parseBrowseEntry(payload: String) {
        // <type>:<size>:<name>     type 0=file, 1=dir.
        // maxSplits=2 → name preserves any colons.
        let parts = payload.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let type = Int(parts[0]),
              let size = Int64(parts[1]) else { return }
        let name = String(parts[2])
        let isDir = (type == 1)
        let rel = pendingPath.isEmpty ? name : "\(pendingPath)/\(name)"
        pendingEntries.append(DeviceFileEntry(name: name, size: size,
                                              isDirectory: isDir, relativePath: rel))
    }

    private func handleFileOutChunk(_ data: Data) {
        guard case .downloading(let entry, _, _) = phase else { return }
        downloadBuffer.append(data)
        phase = .downloading(entry,
                             bytesDone: Int64(downloadBuffer.count),
                             bytesTotal: downloadExpected)
    }

    private func finishDownload() {
        guard let entry = downloadEntry else { return }
        // Belt-and-braces size check: if FILE_OUT notifications got
        // dropped at the radio layer the file would be short. The device
        // doesn't retransmit, so we surface this as a failure and let
        // the user retry.
        if downloadExpected > 0, Int64(downloadBuffer.count) != downloadExpected {
            phase = .failed("Incomplete transfer (got \(downloadBuffer.count) of \(downloadExpected) bytes). Try again.")
            shutdown()
            return
        }
        // Write to a temp file in Documents/DeviceFiles/ so the share
        // sheet can pick it up by URL.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("DeviceFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(entry.name)
        do {
            try downloadBuffer.write(to: url, options: .atomic)
        } catch {
            phase = .failed("Couldn't save file: \(error.localizedDescription)")
            shutdown()
            return
        }
        phase = .downloaded(entry, url)
        // Drop the in-memory copy now that it's on disk.
        downloadBuffer = Data()
        downloadEntry = nil
    }
}

// MARK: - CBCentralManagerDelegate

extension DeviceFileBrowser: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: nil, options: nil)
        case .poweredOff:
            phase = .failed("Please enable Bluetooth")
            shutdown()
        case .unauthorized:
            phase = .failed("Bluetooth access denied. Enable it in Settings.")
            shutdown()
        case .unsupported:
            phase = .failed("Bluetooth not available on this device")
            shutdown()
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.name == kDeviceName else { return }
        if discoveredPeripherals.isEmpty {
            scanTimer?.invalidate(); scanTimer = nil
            discoveryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.finishDiscovery() }
            }
        }
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
        }
    }

    private func finishDiscovery() {
        central?.stopScan()
        guard let device = discoveredPeripherals.first else {
            phase = .failed("CrossPoint not found")
            shutdown()
            return
        }
        peripheral = device
        phase = .connecting
        central?.connect(device, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        phase = .discovering
        peripheral.discoverServices([kServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        phase = .failed(error?.localizedDescription ?? "Couldn't connect to CrossPoint")
        shutdown()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        switch phase {
        case .listing, .downloading:
            phase = .failed("CrossPoint disconnected")
        default:
            break
        }
    }
}

// MARK: - CBPeripheralDelegate

extension DeviceFileBrowser: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == kServiceUUID }) else {
            phase = .failed("CrossPoint service not found")
            shutdown()
            return
        }
        peripheral.discoverCharacteristics(
            [kControlUUID, kStatusUUID, kInfoUUID, kFileOutUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            phase = .failed("Couldn't read BLE characteristics")
            shutdown()
            return
        }
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case kControlUUID: controlChar = char
            case kStatusUUID:  statusChar = char
            case kInfoUUID:    infoChar = char
            case kFileOutUUID: fileOutChar = char
            default: break
            }
        }
        guard controlChar != nil, let sc = statusChar else {
            phase = .failed("Older firmware — re-flash to enable file browsing")
            shutdown()
            return
        }
        guard let fo = fileOutChar else {
            phase = .failed("Older firmware — re-flash to enable file browsing")
            shutdown()
            return
        }
        peripheral.setNotifyValue(true, for: sc)
        peripheral.setNotifyValue(true, for: fo)
        if let ic = infoChar { peripheral.readValue(for: ic) }
        // BROWSE_LS works without a SYNC_START handshake — it's a
        // standalone command on the firmware side. Start at the
        // /AirBook root (empty relpath).
        loadDirectory("")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == kFileOutUUID {
            if let data = characteristic.value { handleFileOutChunk(data) }
            return
        }
        if characteristic.uuid == kInfoUUID {
            if let data = characteristic.value,
               let info = DeviceFirmwareInfo.parse(data) {
                deviceInfo = info
            }
            return
        }
        if characteristic.uuid == kStatusUUID {
            if let data = characteristic.value,
               let msg = String(data: data, encoding: .utf8) {
                handleStatus(msg)
            }
            return
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            phase = .failed("BLE write error: \(error.localizedDescription)")
            shutdown()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {}
}
