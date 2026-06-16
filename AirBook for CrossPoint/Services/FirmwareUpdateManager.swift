import CoreBluetooth
import CryptoKit
import Foundation

// MARK: - Phase

enum FirmwareUpdatePhase: Equatable {
    case idle
    case downloading(receivedBytes: Int64, totalBytes: Int64)
    case scanning
    case connecting
    case discovering
    case ready                                              // ready to send OTA_START
    case sending(bytesDone: Int64, bytesTotal: Int64)
    case verifying
    case flashing
    case rebooting(secondsRemaining: Int)
    case success(newVersion: String?)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .idle, .success, .failed: return false
        default: return true
        }
    }

    var statusText: String {
        switch self {
        case .idle:                                  return "Ready to update"
        case .downloading:                           return "Downloading firmware..."
        case .scanning:                              return "Searching for CrossPoint..."
        case .connecting:                            return "Connecting..."
        case .discovering:                           return "Negotiating..."
        case .ready:                                 return "Starting update..."
        case .sending:                               return "Sending firmware..."
        case .verifying:                             return "Verifying on device..."
        case .flashing:                              return "Installing on device..."
        case .rebooting(let s) where s > 0:          return "Device rebooting — \(s)s"
        case .rebooting:                             return "Device rebooting..."
        case .success(let v?):                       return "Updated to \(v)"
        case .success:                               return "Update complete"
        case .failed(let msg):                       return "Update failed: \(msg)"
        }
    }
}

// MARK: - BLE constants
//
// Must match BluetoothFileReceiver.h on the device side. Keep these in
// sync with `SyncManager`'s copies — they're the same service.

private let kServiceUUID = CBUUID(string: "8b45f100-9128-4d4f-9a4f-7a0dc1b26b01")
private let kControlUUID = CBUUID(string: "8b45f101-9128-4d4f-9a4f-7a0dc1b26b01")
private let kDataUUID    = CBUUID(string: "8b45f102-9128-4d4f-9a4f-7a0dc1b26b01")
private let kStatusUUID  = CBUUID(string: "8b45f103-9128-4d4f-9a4f-7a0dc1b26b01")
private let kInfoUUID    = CBUUID(string: "8b45f104-9128-4d4f-9a4f-7a0dc1b26b01")
private let kDeviceName  = "CrossPoint AirBook"

// MARK: - Manager

@MainActor
@Observable
final class FirmwareUpdateManager: NSObject {
    /// Last-known device firmware info. Populated by the lightweight
    /// `checkDeviceVersion()` flow (connect → read info → disconnect) and
    /// kept around between sheet opens so the UI doesn't go blank between
    /// connections.
    private(set) var deviceInfo: DeviceFirmwareInfo?
    private(set) var phase: FirmwareUpdatePhase = .idle
    /// Ring buffer of the most recent BLE control/status lines — useful
    /// to debug a flash that gets stuck in flashing/rebooting without
    /// throwing an OTA_ERROR. Mirrors SyncManager's traceLog so the
    /// SyncDiagnosticsView pattern can be reused if we ever surface it.
    private(set) var traceLog: [String] = []

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

    // Operation state
    @ObservationIgnored private var mode: Mode = .none
    @ObservationIgnored private var firmwareBytes: Data = Data()
    @ObservationIgnored private var uploadOffset: Int = 0
    @ObservationIgnored private var chunkSize: Int = 512
    @ObservationIgnored private var release: FirmwareReleaseInfo?

    /// Where we expect the device to come back after the reboot. Computed
    /// from the chosen release tag so we can sanity-check the new version
    /// after the device reappears.
    @ObservationIgnored private var expectedNewVersion: String?
    @ObservationIgnored private var rebootCountdownTimer: Timer?

    private enum Mode {
        case none
        case versionProbe          // connect → read info → disconnect
        case fullUpdate            // download + connect + stream + reboot + verify
    }

    private let traceCap = 80

    // MARK: - Public API

    /// Quick BLE round-trip to read the device's Info characteristic.
    /// Doesn't touch the OTA flow. Disconnects once the read completes.
    func checkDeviceVersion() {
        guard !phase.isActive else { return }
        reset()
        mode = .versionProbe
        phase = .scanning
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
        armScanTimeout()
    }

    /// Download `release.downloadURL`, then connect to the device and
    /// stream the .bin. Phase transitions drive the UI.
    func startUpdate(to release: FirmwareReleaseInfo) {
        guard !phase.isActive else { return }
        reset()
        mode = .fullUpdate
        self.release = release
        self.expectedNewVersion = release.version

        Task { [weak self] in
            await self?.downloadAndStart(release)
        }
    }

    func cancel() {
        // Tell the device to drop the in-flight OTA if it's already
        // streaming; from .verifying onward the device-side flash isn't
        // interruptible — we just disconnect and let the device finish.
        switch phase {
        case .sending, .ready:
            writeControl("CANCEL")
        default: break
        }
        rebootCountdownTimer?.invalidate(); rebootCountdownTimer = nil
        phase = .failed("Cancelled")
        shutdown()
    }

    /// Reset to idle so a failed update can be retried without re-creating
    /// the manager. Callers must check `!phase.isActive` first.
    func resetToIdle() {
        guard !phase.isActive else { return }
        phase = .idle
    }

    // MARK: - Download

    private func downloadAndStart(_ release: FirmwareReleaseInfo) async {
        phase = .downloading(receivedBytes: 0, totalBytes: release.sizeBytes)
        do {
            let (data, response) = try await URLSession.shared.data(from: release.downloadURL)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                phase = .failed("Couldn't download firmware")
                return
            }
            firmwareBytes = data
            phase = .scanning
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: true])
            armScanTimeout()
        } catch {
            phase = .failed("Couldn't download firmware: \(error.localizedDescription)")
        }
    }

    // MARK: - State helpers

    private func reset() {
        scanTimer?.invalidate(); scanTimer = nil
        discoveryTimer?.invalidate(); discoveryTimer = nil
        rebootCountdownTimer?.invalidate(); rebootCountdownTimer = nil
        firmwareBytes = Data()
        uploadOffset = 0
        discoveredPeripherals = []
        controlChar = nil
        dataChar = nil
        statusChar = nil
        infoChar = nil
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

    private func armScanTimeout() {
        scanTimer?.invalidate()
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

    private func shutdown() {
        scanTimer?.invalidate(); scanTimer = nil
        discoveryTimer?.invalidate(); discoveryTimer = nil
        central?.stopScan()
        if let p = peripheral {
            central?.cancelPeripheralConnection(p)
        }
        central?.delegate = nil
        central = nil
        peripheral = nil
        controlChar = nil
        dataChar = nil
        statusChar = nil
        infoChar = nil
        mode = .none
    }

    // MARK: - Status handler

    private func handleStatus(_ raw: String) {
        let msg = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        appendTrace("← \(msg)")

        if msg == "OTA_READY" {
            phase = .sending(bytesDone: 0, bytesTotal: Int64(firmwareBytes.count))
            pumpUpload()
            return
        }
        if msg.hasPrefix("OTA_PROGRESS:") {
            let payload = String(msg.dropFirst("OTA_PROGRESS:".count))
            let parts = payload.split(separator: ":")
            if parts.count == 2,
               let done = Int64(parts[0]),
               let total = Int64(parts[1]) {
                phase = .sending(bytesDone: done, bytesTotal: total)
            }
            pumpUpload()
            return
        }
        if msg == "OTA_VERIFYING" {
            phase = .verifying
            return
        }
        if msg == "OTA_FLASHING" {
            phase = .flashing
            return
        }
        if msg == "OTA_REBOOTING" {
            // Device is about to ESP.restart(); the BLE link will drop
            // any moment. Kick off the countdown so the UI shows the
            // expected wait, and shut our side down — we'll reconnect
            // briefly to re-read the Info characteristic and confirm the
            // new version landed.
            phase = .rebooting(secondsRemaining: 25)
            startRebootCountdown()
            shutdown()
            return
        }
        if msg.hasPrefix("OTA_ERROR:") {
            let body = String(msg.dropFirst("OTA_ERROR:".count))
            phase = .failed(body.isEmpty ? "Device rejected firmware" : body)
            shutdown()
            return
        }
        if msg == "CANCELLED" && (phase == .ready || (phase.isActive && phase != .verifying && phase != .flashing)) {
            // Device-initiated cancel during early OTA. .verifying/.flashing
            // are post-cancellable on the device, so don't claim cancel here.
            phase = .failed("Cancelled on device")
            shutdown()
            return
        }
        // ERROR:<msg> can arrive when we send an OTA control that the
        // firmware version on the device doesn't know yet (e.g. very old
        // build that pre-dates the OTA support).
        if msg.hasPrefix("ERROR:") {
            let body = String(msg.dropFirst("ERROR:".count))
            phase = .failed(body.isEmpty ? "Device error" : body)
            shutdown()
            return
        }
    }

    private func startRebootCountdown() {
        rebootCountdownTimer?.invalidate()
        rebootCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                if case .rebooting(let s) = self.phase {
                    let next = s - 1
                    if next > 0 {
                        self.phase = .rebooting(secondsRemaining: next)
                    } else {
                        timer.invalidate()
                        self.rebootCountdownTimer = nil
                        self.verifyPostReboot()
                    }
                } else {
                    timer.invalidate()
                    self.rebootCountdownTimer = nil
                }
            }
        }
    }

    private func verifyPostReboot() {
        // Open a fresh BLE session in version-probe mode. If the device
        // comes back with a new version string, we report success with
        // it; if it doesn't show up at all, we still report success
        // (the OTA almost certainly worked — device might be slow to
        // re-advertise, or the user already moved away).
        mode = .versionProbe
        phase = .scanning
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
        // Shorter timeout for post-reboot probe — we'd rather declare
        // success after 10s than leave the user staring at "scanning".
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if case .scanning = self.phase {
                    self.phase = .success(newVersion: self.expectedNewVersion)
                    self.shutdown()
                }
            }
        }
    }

    // MARK: - Upload pump

    private func sendOtaStart() {
        // SHA-256 of the firmware payload, lowercase hex — matches the
        // device-side parser which compares the literal hex string.
        let digest = SHA256.hash(data: firmwareBytes)
        let sha = digest.map { String(format: "%02x", $0) }.joined()
        phase = .ready
        writeControl("OTA_START:\(firmwareBytes.count):\(sha)")
        // Device will reply OTA_READY → pumpUpload() kicks in via
        // handleStatus.
    }

    private func pumpUpload() {
        guard let p = peripheral, let dc = dataChar else { return }
        let total = firmwareBytes.count
        guard total > 0 else { return }
        while uploadOffset < total && p.canSendWriteWithoutResponse {
            let end = min(uploadOffset + chunkSize, total)
            p.writeValue(firmwareBytes.subdata(in: uploadOffset..<end),
                         for: dc, type: .withoutResponse)
            uploadOffset = end
        }
        // Phase is intentionally not updated from uploadOffset here. iOS's
        // GATT queue is large enough that uploadOffset rockets to total in
        // a single pumpUpload(), while bytes only trickle over the radio at
        // ~30 KB/s. The user would see the bar jump to 100% and then snap
        // back down to whatever OTA_PROGRESS reports — that's the glitch.
        // Device-reported OTA_PROGRESS is the truth, so we let the status
        // handler update the bar exclusively.

        if uploadOffset >= total {
            writeControl("OTA_END")
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension FirmwareUpdateManager: CBCentralManagerDelegate {
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
        // Disconnects in the rebooting phase are expected — the device is
        // restarting and we'll reconnect for the version probe.
        if case .rebooting = phase { return }
        if !phase.isActive { return }
        // Mid-OTA disconnect = failure. The user can retry.
        phase = .failed("CrossPoint disconnected unexpectedly")
    }
}

// MARK: - CBPeripheralDelegate

extension FirmwareUpdateManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == kServiceUUID }) else {
            phase = .failed("CrossPoint service not found")
            shutdown()
            return
        }
        peripheral.discoverCharacteristics(
            [kControlUUID, kDataUUID, kStatusUUID, kInfoUUID], for: service)
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
            case kDataUUID:    dataChar = char
            case kStatusUUID:  statusChar = char
            case kInfoUUID:    infoChar = char
            default: break
            }
        }

        // Subscribe to status notifications. Required for OTA progress
        // updates; harmless during version probe.
        if let sc = statusChar {
            peripheral.setNotifyValue(true, for: sc)
        }

        // Read the Info characteristic up front so deviceInfo is available
        // even in OTA mode (the UI can confirm "updating from X to Y").
        if let ic = infoChar {
            peripheral.readValue(for: ic)
        } else {
            // Older firmware doesn't expose Info char yet. We still allow
            // OTA to proceed, but the version display will say "unknown".
            // For a version-probe call, however, no Info char means
            // there's nothing to do — disconnect and report failure so
            // the UI can fall back gracefully.
            if mode == .versionProbe {
                phase = .failed("Device firmware predates version reporting. Update via SD card to bootstrap.")
                shutdown()
                return
            }
        }

        chunkSize = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        // For full-update mode we'll kick off OTA_START once the Info char
        // read lands — handled in didUpdateValueFor. For version-probe
        // mode the same callback also disconnects after publishing
        // deviceInfo. If there's no Info char (older firmware) we already
        // bailed above in the OTA path or version-probe path.
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == kInfoUUID {
            if let data = characteristic.value,
               let info = DeviceFirmwareInfo.parse(data) {
                deviceInfo = info
                appendTrace("info: fw=\(info.version) caps=\(info.capabilities.sorted().joined(separator: ","))")
            }
            switch mode {
            case .versionProbe:
                // Job done — disconnect.
                phase = .success(newVersion: deviceInfo?.version)
                shutdown()
            case .fullUpdate:
                // We have the device version; now stream the firmware.
                sendOtaStart()
            case .none:
                break
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

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if case .sending = phase {
            pumpUpload()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {}
}
