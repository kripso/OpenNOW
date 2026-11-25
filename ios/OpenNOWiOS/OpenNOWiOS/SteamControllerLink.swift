#if os(iOS)
import CoreBluetooth
import Foundation

/// The Bluetooth connection to a Steam Controller.
///
/// The pad must already be paired with the device in the system's Bluetooth settings. This finds
/// it among the system's connected accessories, subscribes to its raw state, and keeps telling it
/// not to act as a keyboard and mouse on its own. When nothing needs the pad any more the
/// connection is dropped and the pad returns to that built-in behaviour by itself.
///
/// Nothing is scanned for unless `scan` is called, so an active stream never shares the radio
/// with a Bluetooth scan.
final class SteamControllerLink: NSObject, ObservableObject {
    enum Status: Equatable {
        case off
        case bluetoothOff
        case notAllowed
        case unsupported
        case searching
        case connecting(String)
        case connected(String)
    }

    static let shared = SteamControllerLink()

    @Published private(set) var status: Status = .off
    @Published private(set) var scanning = false
    /// The latest state at a rate a settings screen can draw; nil when no pad is connected.
    @Published private(set) var preview: SteamControllerReport?
    /// Recent connection events, newest last, for the player to read or send on.
    @Published private(set) var events: [String] = []

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    /// Whether the pad should send gyro readings. They cost radio time, so they are off unless a
    /// layout uses them.
    var gyroEnabled = false {
        didSet {
            guard gyroEnabled != oldValue else { return }
            decoders.keys.forEach { decoders[$0]?.resetGyroClock() }
            writeSettings()
        }
    }

    private static let searchInterval: TimeInterval = 2
    private static let connectTimeout: TimeInterval = 20
    private static let rejectionPeriod: TimeInterval = 30
    private static let previewInterval: TimeInterval = 0.1
    private static let maximumEvents = 40

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var stateCharacteristics: [CBCharacteristic] = []
    private var activeState: CBCharacteristic?
    private var settingsCharacteristic: CBCharacteristic?
    private var rumbleCharacteristic: CBCharacteristic?
    private var decoders: [CBUUID: SteamControllerReportDecoder] = [:]
    private var users: Set<ObjectIdentifier> = []
    private var observers: [ObjectIdentifier: (SteamControllerReport) -> Void] = [:]
    private var rejected: [UUID: Date] = [:]
    private var searchTimer: Timer?
    private var connectTimer: Timer?
    private var subscribeTimer: Timer?
    private var settingsTimer: Timer?
    private var rumbleTimer: Timer?
    private var scanTimer: Timer?
    private var rumble: (low: UInt16, high: UInt16) = (0, 0)
    private var lastPreviewAt: TimeInterval = 0
    private var reportedWriteFailure = false

    private let valveService = CBUUID(string: SteamControllerProtocol.serviceUUID)
    private let deviceInformation = CBUUID(string: SteamControllerProtocol.deviceInformationServiceUUID)
    private let stateUUIDs: [CBUUID: SteamControllerReportDecoder.Format] = [
        CBUUID(string: SteamControllerProtocol.stateCharacteristicUUID): .standard,
        CBUUID(string: SteamControllerProtocol.timestampedStateCharacteristicUUID): .timestamped
    ]
    private let settingsUUID = CBUUID(string: SteamControllerProtocol.settingsCharacteristicUUID)
    private let rumbleUUID = CBUUID(string: SteamControllerProtocol.rumbleCharacteristicUUID)

    /// Keeps the link running for as long as `user` needs it and delivers every report to
    /// `handler` on the main queue. The first use asks the player for Bluetooth access.
    func attach(_ user: AnyObject, handler: ((SteamControllerReport) -> Void)? = nil) {
        let id = ObjectIdentifier(user)
        users.insert(id)
        observers[id] = handler
        start()
    }

    func detach(_ user: AnyObject) {
        let id = ObjectIdentifier(user)
        observers[id] = nil
        guard users.remove(id) != nil, users.isEmpty else { return }
        stop()
    }

    /// Looks for a pad that is advertising, for a first connection the system has not made yet.
    func scan(for duration: TimeInterval = 15) {
        guard let central, central.state == .poweredOn, peripheral == nil, !scanning else { return }
        note("Scanning for a Steam Controller")
        scanning = true
        central.scanForPeripherals(withServices: nil)
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.stopScan()
        }
    }

    /// Runs both motors at the given speeds until told otherwise; zero stops them.
    func setRumble(lowFrequency: UInt16, highFrequency: UInt16) {
        let next = (low: lowFrequency, high: highFrequency)
        guard next != rumble else { return }
        rumble = next
        rumbleTimer?.invalidate()
        rumbleTimer = nil
        writeRumble()
        guard next != (0, 0) else { return }
        rumbleTimer = Timer.scheduledTimer(
            withTimeInterval: SteamControllerProtocol.rumbleRepeatInterval, repeats: true
        ) { [weak self] _ in self?.writeRumble() }
    }

    private func start() {
        switch CBCentralManager.authorization {
        case .denied, .restricted:
            status = .notAllowed
            return
        default:
            break
        }
        if let central {
            centralManagerDidUpdateState(central)
        } else {
            status = .searching
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    private func stop() {
        stopScan()
        searchTimer?.invalidate()
        searchTimer = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        forgetPeripheral()
        status = .off
    }

    private func stopScan() {
        scanTimer?.invalidate()
        scanTimer = nil
        guard scanning else { return }
        scanning = false
        central?.stopScan()
    }

    private func beginSearch() {
        guard !users.isEmpty, let central, central.state == .poweredOn, peripheral == nil else { return }
        status = .searching
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: Self.searchInterval, repeats: true) { [weak self] _ in
            self?.findConnectedPad()
        }
        findConnectedPad()
    }

    private func findConnectedPad() {
        guard let central, central.state == .poweredOn, peripheral == nil else { return }
        let now = Date()
        rejected = rejected.filter { now.timeIntervalSince($0.value) < Self.rejectionPeriod }
        let candidates = central.retrieveConnectedPeripherals(withServices: [valveService, deviceInformation])
        guard let pad = candidates.first(where: {
            ($0.name ?? "").hasPrefix(SteamControllerProtocol.namePrefix) && rejected[$0.identifier] == nil
        }) else { return }
        connect(pad)
    }

    private func connect(_ pad: CBPeripheral) {
        guard let central, peripheral == nil else { return }
        stopScan()
        searchTimer?.invalidate()
        searchTimer = nil
        peripheral = pad
        pad.delegate = self
        let name = pad.name ?? SteamControllerProtocol.namePrefix
        status = .connecting(name)
        note("Connecting to \(name)")
        central.connect(pad)
        connectTimer?.invalidate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: Self.connectTimeout, repeats: false) { [weak self] _ in
            guard let self, let pad = self.peripheral, self.activeState == nil else { return }
            self.reject(pad, reason: "No input arrived within \(Int(Self.connectTimeout)) seconds")
        }
    }

    /// Gives up on a pad for a while so a device that cannot be used is not retried in a loop.
    private func reject(_ pad: CBPeripheral, reason: String) {
        note(reason)
        rejected[pad.identifier] = Date()
        central?.cancelPeripheralConnection(pad)
        forgetPeripheral()
        beginSearch()
    }

    private func forgetPeripheral() {
        [connectTimer, subscribeTimer, settingsTimer, rumbleTimer].forEach { $0?.invalidate() }
        connectTimer = nil
        subscribeTimer = nil
        settingsTimer = nil
        rumbleTimer = nil
        peripheral?.delegate = nil
        peripheral = nil
        stateCharacteristics = []
        activeState = nil
        settingsCharacteristic = nil
        rumbleCharacteristic = nil
        decoders = [:]
        rumble = (0, 0)
        reportedWriteFailure = false
        preview = nil
    }

    private func subscribe() {
        guard let peripheral, activeState == nil else { return }
        stateCharacteristics.forEach { peripheral.setNotifyValue(true, for: $0) }
    }

    private func writeSettings() {
        guard let peripheral, let settingsCharacteristic, activeState != nil else { return }
        peripheral.writeValue(SteamControllerProtocol.settings(gyro: gyroEnabled), for: settingsCharacteristic,
                              type: .withResponse)
    }

    private func writeRumble() {
        guard let peripheral, let rumbleCharacteristic, activeState != nil else { return }
        let type: CBCharacteristicWriteType =
            rumbleCharacteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(
            SteamControllerProtocol.rumble(lowFrequency: rumble.low, highFrequency: rumble.high),
            for: rumbleCharacteristic, type: type)
    }

    private func note(_ event: String) {
        let stamp = Self.clock.string(from: Date())
        events = Array((events + ["\(stamp)  \(event)"]).suffix(Self.maximumEvents))
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

extension SteamControllerLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            beginSearch()
        case .poweredOff:
            forgetPeripheral()
            stopScan()
            status = users.isEmpty ? .off : .bluetoothOff
        case .unauthorized:
            status = .notAllowed
        case .unsupported:
            status = .unsupported
        default:
            if !users.isEmpty { status = .searching }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard name.hasPrefix(SteamControllerProtocol.namePrefix), rejected[peripheral.identifier] == nil else { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([valveService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        reject(peripheral, reason: "Could not connect: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        note("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        forgetPeripheral()
        beginSearch()
    }
}

extension SteamControllerLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == valveService }) else {
            reject(peripheral, reason: "This device does not offer the Steam Controller service")
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, service.uuid == valveService else { return }
        let characteristics = service.characteristics ?? []
        stateCharacteristics = characteristics.filter { stateUUIDs[$0.uuid] != nil }
        settingsCharacteristic = characteristics.first { $0.uuid == settingsUUID }
        rumbleCharacteristic = characteristics.first { $0.uuid == rumbleUUID }
        for characteristic in stateCharacteristics {
            decoders[characteristic.uuid] = stateUUIDs[characteristic.uuid].map(SteamControllerReportDecoder.init(format:))
        }
        guard !stateCharacteristics.isEmpty else {
            let found = characteristics.map { $0.uuid.uuidString }.joined(separator: ", ")
            reject(peripheral, reason: "No known input characteristic (found \(found))")
            return
        }
        note("Found input (\(stateCharacteristics.count)), settings \(settingsCharacteristic != nil ? "yes" : "no"), "
            + "rumble \(rumbleCharacteristic != nil ? "yes" : "no")")
        // Until the player accepts a pairing request the subscription silently does nothing, and
        // nothing reports that it was accepted, so it is repeated until input arrives.
        subscribe()
        subscribeTimer?.invalidate()
        subscribeTimer = Timer.scheduledTimer(withTimeInterval: Self.searchInterval, repeats: true) { [weak self] _ in
            self?.subscribe()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, stateUUIDs[characteristic.uuid] != nil,
              let data = characteristic.value else { return }
        if activeState == nil {
            activeState = characteristic
            connectTimer?.invalidate()
            subscribeTimer?.invalidate()
            connectTimer = nil
            subscribeTimer = nil
            // Firmware sends one of the two formats; listening to the other only costs radio time.
            for other in stateCharacteristics where other !== characteristic { peripheral.setNotifyValue(false, for: other) }
            let name = peripheral.name ?? SteamControllerProtocol.namePrefix
            status = .connected(name)
            note("Receiving input from \(name) (\(data.count) bytes per report)")
            writeSettings()
            settingsTimer = Timer.scheduledTimer(
                withTimeInterval: SteamControllerProtocol.settingsRepeatInterval, repeats: true
            ) { [weak self] _ in self?.writeSettings() }
        }
        guard characteristic === activeState, let report = decoders[characteristic.uuid]?.decode(data) else { return }
        observers.values.forEach { $0(report) }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPreviewAt >= Self.previewInterval {
            lastPreviewAt = now
            preview = report
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let error, !reportedWriteFailure else { return }
        reportedWriteFailure = true
        note("The pad refused a write to \(characteristic.uuid.uuidString): \(error.localizedDescription)")
    }
}
#endif
