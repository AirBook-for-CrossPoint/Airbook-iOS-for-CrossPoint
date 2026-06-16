import CoreBluetooth
import Foundation

/// Lightweight passive BLE scanner used by the home screen to detect
/// whether a CrossPoint device is advertising nearby. Re-probes every
/// `rescanIntervalSeconds` while enabled so the status dot reflects the
/// current state — if the device walks away or stops advertising (e.g.
/// the user closed AirBook sync on the reader), `isNearby` flips back
/// to false at the end of the next cycle.
@MainActor
@Observable
final class DeviceScanner: NSObject {
    var isNearby: Bool = false
    var isScanning: Bool = false

    /// Window each cycle stays in scan mode before deciding. Tuned to be
    /// long enough to catch a CrossPoint at standard advertising intervals
    /// (~1 s) but short enough to keep BLE off most of the time.
    @ObservationIgnored private let scanWindowSeconds: TimeInterval = 8
    /// Gap between cycles. Combined with scanWindowSeconds this gives a
    /// ~12% radio duty cycle while the home screen is in the foreground.
    @ObservationIgnored private let rescanIntervalSeconds: TimeInterval = 60

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var scanTimeout: Timer?
    @ObservationIgnored private var rescanTimer: Timer?
    @ObservationIgnored private var enabled: Bool = false
    @ObservationIgnored private var foundInCurrentCycle: Bool = false

    func startScan() {
        enabled = true
        if isScanning { return }
        startCycle()
    }

    func stopScan() {
        enabled = false
        scanTimeout?.invalidate(); scanTimeout = nil
        rescanTimer?.invalidate(); rescanTimer = nil
        central?.stopScan()
        central?.delegate = nil
        central = nil
        isScanning = false
    }

    private func startCycle() {
        rescanTimer?.invalidate(); rescanTimer = nil
        foundInCurrentCycle = false
        isScanning = true
        // Intentionally don't reset isNearby here — flipping it to false
        // for the 8 s scan window would make the dot blink even when the
        // device is in range. We only flip it false at endCycle() if the
        // window expired without a discovery.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    private func endCycle() {
        scanTimeout?.invalidate(); scanTimeout = nil
        central?.stopScan()
        central?.delegate = nil
        central = nil
        isScanning = false
        if !foundInCurrentCycle {
            isNearby = false
        }
        // Schedule the next cycle so the dot stays fresh while the home
        // screen is up. Stopped explicitly on stopScan().
        if enabled {
            rescanTimer?.invalidate()
            rescanTimer = Timer.scheduledTimer(withTimeInterval: rescanIntervalSeconds,
                                                repeats: false) { [weak self] _ in
                Task { @MainActor in self?.startCycle() }
            }
        }
    }
}

extension DeviceScanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            scanTimeout = Timer.scheduledTimer(withTimeInterval: scanWindowSeconds,
                                                repeats: false) { [weak self] _ in
                Task { @MainActor in self?.endCycle() }
            }
        } else {
            stopScan()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if peripheral.name == "CrossPoint AirBook" {
            isNearby = true
            foundInCurrentCycle = true
            endCycle()
        }
    }
}
