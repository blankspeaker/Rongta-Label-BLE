// SPDX-License-Identifier: GPL-3.0-or-later
// rongta-ble sends a CUPS job to a Rongta label printer over Bluetooth LE.
// Service FF00, write characteristic FF02. Chunks use the radio's
// without-response length, capped at 512 bytes.
//
//   rongta-ble --helper                 loopback listener for the CUPS backend
//   rongta-ble --scan                   list nearby printers
//   rongta-ble --uri rongta-bt://RP425 job.bin
//   rongta-ble job user title copies options file
//
// The device URI is rongta-bt://<name-prefix-or-uuid-or-auto>.
// auto matches a name starting with RP4 or any peripheral advertising FF00.
import Foundation
import CoreBluetooth
import Darwin

private let serviceUUID = CBUUID(string: "FF00")
private let writeUUID = CBUUID(string: "FF02")
private let helperPort: UInt16 = 47221
private let maxJobBytes = 16 * 1024 * 1024

private struct Target {
    var auto: Bool
    var uuid: UUID?
    var prefix: String
}

private struct Seen {
    var peripheral: CBPeripheral
    var name: String
    var advertised: Bool
    var rssi: Int
    var rank: Int
    var matchesRongta: Bool
}

extension BluetoothGate.Auth {
    init(_ value: CBManagerAuthorization) {
        switch value {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .allowedAlways: self = .allowedAlways
        @unknown default: self = .unknown
        }
    }
}

extension BluetoothGate.Radio {
    init(_ value: CBManagerState) {
        switch value {
        case .unknown: self = .unknown
        case .resetting: self = .resetting
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .poweredOff: self = .poweredOff
        case .poweredOn: self = .poweredOn
        @unknown default: self = .unknown
        }
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var stored: String

    init(_ initial: String = "ERR scan failed\n") {
        stored = initial
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func finish(_ value: String, _ gate: DispatchSemaphore) {
        lock.lock()
        let first = !done
        if first {
            done = true
            stored = value
        }
        lock.unlock()
        if first {
            gate.signal()
        }
    }

    func cancel() {
        lock.lock()
        done = true
        lock.unlock()
    }
}

private func writeReply(_ fd: Int32, _ reply: String) {
    var text = reply
    if text.isEmpty {
        text = "ERR no reply\n"
    }
    if !text.hasSuffix("\n") {
        text += "\n"
    }
    text.withCString { ptr in
        var off = 0
        let len = Int(strlen(ptr))
        while off < len {
            let n = write(fd, ptr + off, len - off)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            off += n
        }
    }
}

private func log(_ line: String) {
    let text = line.hasSuffix("\n") ? line : line + "\n"
    if let data = text.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/com.blankspeaker.rongta-label.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        _ = try? handle.seekToEnd()
        if let data = text.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        try? handle.close()
    } else if let data = text.data(using: .utf8) {
        try? data.write(to: url)
    }
}

private func parseTarget(_ uri: String) -> Target {
    var text = uri.trimmingCharacters(in: .whitespacesAndNewlines)
    if let range = text.range(of: "://") {
        text = String(text[range.upperBound...])
    }
    if let query = text.firstIndex(of: "?") {
        text = String(text[..<query])
    }
    text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    text = text.removingPercentEncoding ?? text
    if text.isEmpty || text.caseInsensitiveCompare("auto") == .orderedSame || text == "*" {
        return Target(auto: true, uuid: nil, prefix: "RP4")
    }
    if let id = UUID(uuidString: text) {
        return Target(auto: false, uuid: id, prefix: "")
    }
    return Target(auto: false, uuid: nil, prefix: text)
}

private func uriEscape(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func cacheFile() -> URL {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.blankspeaker.rongta-label", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("known-peripherals.txt")
}

private func cachedID(for prefix: String) -> UUID? {
    guard let text = try? String(contentsOf: cacheFile(), encoding: .utf8) else {
        return nil
    }
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        if parts.count == 2 && parts[0].caseInsensitiveCompare(prefix) == .orderedSame {
            return UUID(uuidString: parts[1])
        }
    }
    return nil
}

private func remember(prefix: String, id: UUID) {
    var rows: [String: String] = [:]
    if let text = try? String(contentsOf: cacheFile(), encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                rows[parts[0]] = parts[1]
            }
        }
    }
    rows[prefix] = id.uuidString
    let body = rows.map { "\($0.key)\t\($0.value)" }.sorted().joined(separator: "\n") + "\n"
    try? body.write(to: cacheFile(), atomically: true, encoding: .utf8)
}

private final class BleApp: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // Created on the main run loop, not at startup, and replaced for every
    // scan and print. A manager that already reported unauthorized is not kept.
    var central: CBCentralManager?
    var stateIsLive = false
    var liveUnauthorizedSamples = 0
    var statusCompletion: ((CBCentralManager) -> Void)?
    let operationLock = NSLock()
    var operationBusy = false
    var readyAction: (() -> Void)?
    var readyFailure: ((String) -> Void)?
    var waitingForDecision = false
    var target = Target(auto: true, uuid: nil, prefix: "RP4")
    var payload = Data()
    var peripheral: CBPeripheral?
    var characteristic: CBCharacteristic?
    var offset = 0
    var chunk = 244
    var progressMark = 0
    var sendFinished = false
    var idleDrop: DispatchWorkItem?
    var jobOpen = false
    var scanningList = false
    /// WATCH keeps one scan open and reports signal changes. SCAN still replaces its list.
    var watching = false
    /// SCAN ALL and WATCH ALL list every advertiser. A normal SCAN stays on Rongta matches.
    var listEverything = false
    /// When set, each discovery line is written immediately so the app can update.
    var scanStream: Int32 = -1
    var generation = 0
    var found: [UUID: Seen] = [:]
    var printCompletion: ((String) -> Void)?
    var scanCompletion: ((String) -> Void)?

    func tryBeginOperation() -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        if operationBusy {
            return false
        }
        operationBusy = true
        return true
    }

    func endOperation() {
        operationLock.lock()
        operationBusy = false
        operationLock.unlock()
    }

    /// A new manager when the current one is missing or not ready to print.
    /// A denial is not kept: the next request creates another manager.
    func replaceCentral() {
        dropLink()
        stateIsLive = false
        liveUnauthorizedSamples = 0
        if let existing = central {
            existing.delegate = nil
            existing.stopScan()
        }
        central = nil
        let manager = CBCentralManager(delegate: self, queue: .main)
        if central == nil {
            central = manager
        }
    }

    /// Wait until the delegate has reported, then run `go`.
    /// A powered-on manager is reused so the next job does not wait for a new one.
    /// Authorization is read again on every call. Nothing here remembers a denial.
    func whenReady(_ go: @escaping () -> Void, fail: @escaping (String) -> Void) {
        readyAction = go
        readyFailure = fail
        if let central, stateIsLive,
           central.authorization == .allowedAlways,
           central.state == .poweredOn {
            readyAction = nil
            readyFailure = nil
            go()
            return
        }
        replaceCentral()
        pumpReady()
    }

    func dropLink() {
        idleDrop?.cancel()
        idleDrop = nil
        if let item = peripheral {
            central?.cancelPeripheralConnection(item)
        }
        peripheral = nil
        characteristic = nil
    }

    /// Leave the radio link up briefly so the next label skips discovery.
    func scheduleIdleDrop() {
        idleDrop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.jobOpen else { return }
            if let item = self.peripheral {
                self.central?.cancelPeripheralConnection(item)
            }
            self.peripheral = nil
            self.characteristic = nil
            self.idleDrop = nil
            log("INFO: closed the idle printer link")
        }
        idleDrop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    func linkIsWarm() -> Bool {
        guard let item = peripheral, item.state == .connected, characteristic != nil else {
            return false
        }
        if let id = target.uuid, item.identifier == id {
            return true
        }
        let name = (item.name ?? "").uppercased()
        if !target.prefix.isEmpty && name.hasPrefix(target.prefix.uppercased()) {
            return true
        }
        return target.auto && !name.isEmpty
    }

    func beginWrites(on item: CBPeripheral) {
        let mtu = item.maximumWriteValueLength(for: .withoutResponse)
        if mtu >= 100 {
            chunk = min(512, mtu)
            log("INFO: chunk=\(chunk) bytes=\(payload.count)")
            pump()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.jobOpen else { return }
            let settled = item.maximumWriteValueLength(for: .withoutResponse)
            self.chunk = max(20, min(512, settled))
            log("INFO: chunk=\(self.chunk) bytes=\(self.payload.count)")
            self.pump()
        }
    }

    /// Socket STATUS. Does not create a manager and does not prompt.
    /// `live=no` means this process has not heard from CoreBluetooth yet;
    /// the class property alone is not a grant.
    func statusReport() -> String {
        if Thread.isMainThread {
            return Self.statusLine(central: central, stateIsLive: stateIsLive)
        }
        var line = "ERR status timed out\n"
        let gate = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            line = Self.statusLine(central: self.central, stateIsLive: self.stateIsLive)
            gate.signal()
        }
        _ = gate.wait(timeout: .now() + 2)
        return line
    }

    static func statusLine(central: CBCentralManager?, stateIsLive: Bool) -> String {
        guard let central, stateIsLive else {
            let auth = BluetoothGate.Auth(CBCentralManager.authorization)
            return "OK authorization=\(auth.token) state=none live=no\n"
        }
        let auth = BluetoothGate.Auth(central.authorization)
        let radio = BluetoothGate.Radio(central.state)
        return "OK authorization=\(auth.token) state=\(radio.token) live=yes\n"
    }

    func schedulePump() {
        guard !waitingForDecision else { return }
        waitingForDecision = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.waitingForDecision = false
            self.pumpReady()
        }
    }

    func pumpReady() {
        guard let go = readyAction, let fail = readyFailure, let central else {
            return
        }
        if stateIsLive && central.state == .unauthorized {
            liveUnauthorizedSamples += 1
        }
        let decision = BluetoothGate.step(
            authorization: BluetoothGate.Auth(central.authorization),
            radio: BluetoothGate.Radio(central.state),
            stateIsLive: stateIsLive,
            unauthorizedSamples: liveUnauthorizedSamples
        )
        switch decision {
        case .wait:
            schedulePump()
        case .proceed:
            readyAction = nil
            readyFailure = nil
            go()
        case .fail(let message):
            readyAction = nil
            readyFailure = nil
            let auth = BluetoothGate.Auth(central.authorization).token
            let radio = BluetoothGate.Radio(central.state).token
            log("INFO: \(message.trimmingCharacters(in: .newlines)) authorization=\(auth) state=\(radio)")
            fail(message)
        }
    }

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        if central == nil {
            central = manager
        }
        stateIsLive = true
        if let statusCompletion {
            let callback = statusCompletion
            self.statusCompletion = nil
            callback(manager)
            return
        }
        pumpReady()
    }

    func abandonReady(_ message: String) {
        generation += 1
        readyAction = nil
        readyFailure = nil
        waitingForDecision = false
        if scanCompletion != nil {
            finishScan(message)
        } else if printCompletion != nil {
            finishPrint(message)
        } else {
            central?.stopScan()
            central?.delegate = nil
            central = nil
            stateIsLive = false
        }
    }

    func failActive(_ message: String) {
        if printCompletion != nil {
            finishPrint(message)
        } else if scanCompletion != nil {
            finishScan(message)
        }
    }

    /// A Rongta-shaped advertiser: a name starting with RP4, or service FF00.
    func isRongtaAdvertisement(name: String?, services: [CBUUID]) -> Bool {
        if let name = name?.uppercased(), name.hasPrefix("RP4") {
            return true
        }
        return services.contains(serviceUUID)
    }

    /// Setup scans do not reuse the last print target. Printing still uses `matches`.
    func listingMatch(name: String?, services: [CBUUID]) -> Bool {
        if listEverything {
            return true
        }
        return isRongtaAdvertisement(name: name, services: services)
    }

    func matches(name: String?, services: [CBUUID], id: UUID) -> Bool {
        if let want = target.uuid, want == id {
            return true
        }
        let hasService = services.contains(serviceUUID)
        if target.auto {
            if let name = name?.uppercased(), name.hasPrefix("RP4") {
                return true
            }
            return hasService
        }
        if let name = name?.uppercased(), !target.prefix.isEmpty,
           name.hasPrefix(target.prefix.uppercased()) {
            return true
        }
        return false
    }

    func rank(name: String?, id: UUID) -> Int {
        if let want = target.uuid, want == id {
            return 4
        }
        guard let name = name?.uppercased() else {
            return target.auto ? 1 : 0
        }
        if target.auto {
            return name.hasPrefix("RP4") ? 2 : 1
        }
        let prefix = target.prefix.uppercased()
        if name == prefix {
            return 3
        }
        if name.hasPrefix(prefix) {
            return 2
        }
        return 0
    }

    func note(peripheral foundPeripheral: CBPeripheral, name: String?, rssi: Int, services: [CBUUID]) {
        let accepted = scanningList
            ? listingMatch(name: name, services: services)
            : matches(name: name, services: services, id: foundPeripheral.identifier)
        guard accepted else {
            return
        }
        let advertised = name ?? foundPeripheral.name
        let hasName = !(advertised ?? "").isEmpty
        let id = foundPeripheral.identifier
        let label = hasName ? advertised! : "Unknown device \(id.uuidString.prefix(8))"
        let rongta = isRongtaAdvertisement(name: advertised, services: services)
        let seen = Seen(
            peripheral: foundPeripheral,
            name: label,
            advertised: hasName,
            rssi: rssi,
            rank: rongta ? rank(name: hasName ? label : nil, id: id) : 0,
            matchesRongta: rongta
        )
        if watching {
            let previous = found[id]
            found[id] = seen
            let barsChanged = previous == nil || signalBars(previous!.rssi) != signalBars(seen.rssi)
            let nameChanged = previous == nil || previous!.name != seen.name || previous!.matchesRongta != seen.matchesRongta
            if scanningList && (barsChanged || nameChanged) {
                emitScanLine(devLine(seen))
            }
            return
        }
        let replace: Bool
        if let previous = found[id] {
            replace = seen.rssi >= previous.rssi
        } else {
            replace = true
        }
        if replace {
            found[id] = seen
            if scanningList {
                emitScanLine(devLine(seen))
            }
        }
    }

    /// Same steps as the setup app. Zero is unknown, so a later real reading still counts as a change.
    func signalBars(_ rssi: Int) -> Int {
        if rssi == 0 {
            return 0
        }
        if rssi >= -60 { return 4 }
        if rssi >= -70 { return 3 }
        if rssi >= -80 { return 2 }
        if rssi >= -90 { return 1 }
        return 1
    }

    /// Rongta-named devices keep a name URI. Anything else uses the peripheral UUID.
    func devLine(_ seen: Seen) -> String {
        let id = seen.peripheral.identifier.uuidString
        let safe = seen.name
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\"", with: "")
        let uri: String
        if seen.matchesRongta && seen.advertised {
            uri = "rongta-bt://\(uriEscape(safe))"
        } else {
            uri = "rongta-bt://\(id)"
        }
        let kind = seen.matchesRongta ? "rongta" : "other"
        return "DEV\t\(uri)\t\(safe)\t\(seen.rssi)\t\(kind)\t\(id)"
    }

    func emitScanLine(_ line: String) {
        guard scanStream >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            _ = write(scanStream, base, buf.count)
        }
    }

    func bestSeen() -> Seen? {
        return found.values.max { lhs, rhs in
            if lhs.rank == rhs.rank {
                return lhs.rssi < rhs.rssi
            }
            return lhs.rank < rhs.rank
        }
    }

    func renderFound() -> String {
        let rows = found.values.sorted { lhs, rhs in
            if lhs.rank == rhs.rank {
                return lhs.rssi > rhs.rssi
            }
            return lhs.rank > rhs.rank
        }
        return rows.map { devLine($0) }.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }

    func startScan(seconds: Double, completion: @escaping (String) -> Void) {
        generation += 1
        let gen = generation
        jobOpen = true
        scanningList = true
        watching = false
        found.removeAll()
        scanCompletion = completion
        whenReady({
            self.central?.scanForPeripherals(withServices: nil, options: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                guard self.generation == gen else { return }
                self.finishScan(self.renderFound())
            }
        }, fail: { message in
            guard self.generation == gen else { return }
            self.finishScan(message)
        })
    }

    func startWatch(completion: @escaping (String) -> Void) {
        generation += 1
        let gen = generation
        jobOpen = true
        scanningList = true
        watching = true
        found.removeAll()
        scanCompletion = completion
        whenReady({
            self.central?.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        }, fail: { message in
            guard self.generation == gen else { return }
            self.finishScan(message)
        })
    }

    func finishScan(_ text: String) {
        guard scanCompletion != nil else { return }
        central?.stopScan()
        scanningList = false
        watching = false
        jobOpen = false
        generation += 1
        let callback = scanCompletion
        scanCompletion = nil
        callback?(text)
    }

    func startPrint(uri: String, payload: Data, completion: @escaping (String) -> Void) {
        generation += 1
        let gen = generation
        idleDrop?.cancel()
        idleDrop = nil
        jobOpen = true
        scanningList = false
        watching = false
        self.payload = payload
        offset = 0
        progressMark = 0
        sendFinished = false
        printCompletion = completion
        target = parseTarget(uri)
        if target.uuid == nil && !target.auto {
            target.uuid = cachedID(for: target.prefix)
        }
        let warm = linkIsWarm()
        if !warm {
            found.removeAll()
            peripheral = nil
            characteristic = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            guard self.generation == gen, self.jobOpen else { return }
            self.finishPrint("ERR printer not found or not accepting data (sent \(self.offset)/\(self.payload.count))\n")
        }
        whenReady({
            if self.linkIsWarm() {
                log("INFO: reusing the open printer link")
                self.pump()
            } else {
                self.beginSearch(allowCachedFallback: true)
            }
        }, fail: { message in
            self.finishPrint(message)
        })
    }

    func beginSearch(allowCachedFallback: Bool) {
        guard jobOpen, let central else { return }
        if let id = target.uuid,
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
            if allowCachedFallback && !target.prefix.isEmpty {
                let gen = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    guard self.generation == gen, self.jobOpen, self.characteristic == nil else { return }
                    log("INFO: remembered printer not reachable, scanning")
                    if let current = self.peripheral {
                        self.central?.cancelPeripheralConnection(current)
                    }
                    self.peripheral = nil
                    self.target.uuid = nil
                    self.central?.scanForPeripherals(withServices: nil, options: nil)
                    self.schedulePick()
                }
            }
            return
        }
        let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        for item in connected {
            note(peripheral: item, name: item.name, rssi: 0, services: [serviceUUID])
        }
        if let chosen = bestSeen() {
            connect(chosen.peripheral)
            return
        }
        central.scanForPeripherals(withServices: nil, options: nil)
        schedulePick()
    }

    func schedulePick() {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard self.generation == gen, self.jobOpen, self.peripheral == nil else { return }
            if let chosen = self.bestSeen() {
                self.connect(chosen.peripheral)
                return
            }
            self.schedulePick()
        }
    }

    func connect(_ item: CBPeripheral) {
        guard let central else { return }
        central.stopScan()
        peripheral = item
        item.delegate = self
        central.connect(item, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard jobOpen else { return }
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertised
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        note(peripheral: peripheral, name: name, rssi: RSSI.intValue, services: services)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard jobOpen else { return }
        if let current = self.peripheral, current.identifier != peripheral.identifier {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        self.peripheral = peripheral
        peripheral.delegate = self
        let name = peripheral.name ?? ""
        if !target.auto && target.uuid == nil && !name.isEmpty &&
            !name.uppercased().hasPrefix(target.prefix.uppercased()) {
            log("INFO: skipping \(name)")
            central.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
            central.scanForPeripherals(withServices: nil, options: nil)
            return
        }
        log("INFO: connected \(name.isEmpty ? peripheral.identifier.uuidString : name) id=\(peripheral.identifier.uuidString)")
        if !target.auto && !target.prefix.isEmpty {
            remember(prefix: target.prefix, id: peripheral.identifier)
        }
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("INFO: connect failed \(error?.localizedDescription ?? "")")
        if self.peripheral == peripheral {
            self.peripheral = nil
        }
        guard jobOpen else { return }
        central.scanForPeripherals(withServices: nil, options: nil)
        schedulePick()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if jobOpen && self.peripheral == peripheral && characteristic != nil && offset < payload.count {
            finishPrint("ERR disconnected while sending\n")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard jobOpen else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            finishPrint("ERR This device has no compatible printer connection. Rongta Label Setup looks for service FF00 and writable characteristic FF02.\n")
            return
        }
        peripheral.discoverCharacteristics([writeUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard jobOpen else { return }
        guard let foundChar = service.characteristics?.first(where: { $0.uuid == writeUUID }) else {
            finishPrint("ERR This device has no compatible printer connection. Rongta Label Setup looks for service FF00 and writable characteristic FF02.\n")
            return
        }
        characteristic = foundChar
        beginWrites(on: peripheral)
    }

    func noteProgress(force: Bool) {
        if !force && progressMark != 0 && offset - progressMark < 16384 && offset < payload.count {
            return
        }
        progressMark = offset
        log("INFO: \(offset)/\(payload.count)")
    }

    func pump() {
        guard jobOpen, let item = peripheral, let char = characteristic else { return }
        while offset < payload.count && item.canSendWriteWithoutResponse {
            let end = min(offset + chunk, payload.count)
            let last = end == payload.count
            // The last chunk is write-with-response. That ack is the barrier that
            // the earlier without-response writes have been delivered.
            item.writeValue(payload.subdata(in: offset..<end), for: char,
                            type: last ? .withResponse : .withoutResponse)
            offset = end
            noteProgress(force: last)
            if last {
                let gen = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    guard self.generation == gen, self.jobOpen else { return }
                    self.completeAfterBarrier()
                }
            }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if offset < payload.count {
            pump()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("INFO: write response \(error.localizedDescription)")
            finishPrint("ERR write failed\n")
            return
        }
        completeAfterBarrier()
    }

    /// The last chunk is write-with-response. Its callback finishes the job.
    /// The 5 s timer is only the fallback when that callback never arrives.
    func completeAfterBarrier() {
        if sendFinished || offset < payload.count {
            return
        }
        sendFinished = true
        finishPrint("OK sent \(payload.count) bytes\n")
    }

    func finishPrint(_ message: String) {
        guard printCompletion != nil else { return }
        let ok = message.hasPrefix("OK")
        jobOpen = false
        generation += 1
        central?.stopScan()
        if ok {
            scheduleIdleDrop()
        } else if message.contains("permission") || message.contains("Bluetooth is off") {
            idleDrop?.cancel()
            idleDrop = nil
            if let item = peripheral {
                central?.cancelPeripheralConnection(item)
            }
            central?.delegate = nil
            central = nil
            stateIsLive = false
            peripheral = nil
            characteristic = nil
        } else {
            dropLink()
        }
        let callback = printCompletion
        printCompletion = nil
        if message.hasPrefix("OK") {
            log("sent \(payload.count) bytes")
        } else {
            log(message.trimmingCharacters(in: .newlines))
        }
        callback?(message)
    }

    func performScan(seconds: Double) -> String {
        if !tryBeginOperation() {
            return "ERR scan in progress\n"
        }
        defer { endOperation() }
        let gate = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        DispatchQueue.main.async {
            self.startScan(seconds: seconds) { text in
                box.finish(text, gate)
            }
        }
        // The scan itself is short. The extra time is for the permission prompt.
        if gate.wait(timeout: .now() + seconds + 45) == .timedOut {
            box.cancel()
            DispatchQueue.main.sync {
                self.abandonReady("ERR Bluetooth permission timed out\n")
            }
            return "ERR Bluetooth permission timed out\n"
        }
        return box.text
    }

    /// Scans until the setup app closes the socket. Devices stay in `found` for the whole session.
    func performWatch(client: Int32) -> String {
        if !tryBeginOperation() {
            return "ERR scan in progress\n"
        }
        defer { endOperation() }
        let gate = DispatchSemaphore(value: 0)
        let box = ReplyBox("")
        DispatchQueue.main.async {
            self.startWatch { text in
                box.finish(text, gate)
            }
        }
        var pfd = pollfd(fd: client, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        while true {
            if gate.wait(timeout: .now()) == .success {
                break
            }
            pfd.revents = 0
            let rc = poll(&pfd, 1, 200)
            if rc < 0 {
                if errno == EINTR { continue }
                break
            }
            if rc == 0 { continue }
            let events = pfd.revents
            if (events & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
                break
            }
            if (events & Int16(POLLIN)) != 0 {
                var scratch = [UInt8](repeating: 0, count: 256)
                let n = read(client, &scratch, scratch.count)
                if n == 0 { break }
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    break
                }
            }
        }
        DispatchQueue.main.sync {
            if self.scanCompletion != nil {
                self.finishScan("")
            }
        }
        let text = box.text
        if text.hasPrefix("ERR") {
            return text
        }
        return "END\nOK\n"
    }

    func performPrint(uri: String, payload: Data) -> String {
        if !tryBeginOperation() {
            return "ERR busy\n"
        }
        defer { endOperation() }
        let gate = DispatchSemaphore(value: 0)
        let box = ReplyBox("ERR internal\n")
        DispatchQueue.main.async {
            self.startPrint(uri: uri, payload: payload) { text in
                let line = text.isEmpty ? "ERR internal\n" : text
                box.finish(line, gate)
            }
        }
        if gate.wait(timeout: .now() + 100) == .timedOut {
            box.cancel()
            DispatchQueue.main.sync {
                self.abandonReady("ERR printer timed out\n")
            }
            return "ERR printer timed out\n"
        }
        let text = box.text
        return text.isEmpty ? "ERR internal\n" : text
    }

    func serve() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            log("ERROR: socket failed")
            exit(1)
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = helperPort.bigEndian
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 || listen(fd, 2) != 0 {
            log("ERROR: cannot listen on 127.0.0.1:\(helperPort)")
            exit(1)
        }
        log("INFO: listening on 127.0.0.1:\(helperPort)")
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                continue
            }
            var peer = sockaddr_in()
            var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let peered = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getpeername(client, $0, &peerLen)
                }
            }
            var loopback = in_addr()
            _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &loopback) }
            if peered != 0 || peer.sin_addr.s_addr != loopback.s_addr {
                close(client)
                continue
            }
            var timeout = timeval(tv_sec: 120, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            // STATUS has to answer while a scan is waiting on Bluetooth.
            DispatchQueue.global(qos: .userInitiated).async {
                let reply = self.handle(client)
                writeReply(client, reply)
                close(client)
            }
        }
    }

    func handle(_ client: Int32) -> String {
        guard let (line, body) = readRequest(client) else {
            return "ERR read\n"
        }
        if line == "STATUS" || line.hasPrefix("STATUS ") {
            return statusReport()
        }
        if line == "WATCH ALL" || line.hasPrefix("WATCH ALL ") || line == "WATCH" || line.hasPrefix("WATCH ") {
            listEverything = line == "WATCH ALL" || line.hasPrefix("WATCH ALL ")
            scanStream = client
            let listing = performWatch(client: client)
            scanStream = -1
            listEverything = false
            watching = false
            return listing
        }
        if line == "SCAN ALL" || line.hasPrefix("SCAN ALL ") || line == "SCAN" || line.hasPrefix("SCAN ") {
            listEverything = line == "SCAN ALL" || line.hasPrefix("SCAN ALL ")
            scanStream = client
            let listing = performScan(seconds: 4)
            scanStream = -1
            listEverything = false
            if listing.hasPrefix("ERR") {
                return listing
            }
            // END marks the final snapshot so earlier live lines can be dropped.
            return "END\n" + listing + "OK\n"
        }
        if line.hasPrefix("PRINT ") {
            let uri = String(line.dropFirst("PRINT ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty {
                return "ERR empty\n"
            }
            if body.count >= maxJobBytes {
                return "ERR job too large\n"
            }
            return performPrint(uri: uri.isEmpty ? "rongta-bt://auto" : uri, payload: body)
        }
        return "ERR protocol\n"
    }
}

private func readRequest(_ fd: Int32) -> (String, Data)? {
    var header = Data()
    var byte: UInt8 = 0
    while header.count < 1024 {
        let n = read(fd, &byte, 1)
        if n == 0 {
            return nil
        }
        if n < 0 {
            if errno == EINTR {
                continue
            }
            return nil
        }
        if byte == 10 {
            break
        }
        if byte != 13 {
            header.append(byte)
        }
    }
    guard let line = String(data: header, encoding: .utf8) else {
        return nil
    }
    if line == "SCAN" || line.hasPrefix("SCAN ") || line == "STATUS" || line.hasPrefix("STATUS ")
        || line == "WATCH" || line.hasPrefix("WATCH ") {
        return (line, Data())
    }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 16384)
    while body.count < maxJobBytes {
        let n = read(fd, &buffer, buffer.count)
        if n == 0 {
            break
        }
        if n < 0 {
            if errno == EINTR {
                continue
            }
            return nil
        }
        body.append(contentsOf: buffer[0..<n])
    }
    return (line, body)
}

private func readFile(_ path: String) -> Data? {
    if path == "-" {
        return FileHandle.standardInput.readDataToEndOfFile()
    }
    return FileManager.default.contents(atPath: path)
}

private func usage() {
    log("usage: rongta-ble --helper | --scan | --scan-all | --scan-client | --send URI file|- | --status | --uri rongta-bt://NAME file")
}

/// Port of the launchd helper. Tests may point this at a stand-in listener.
private func configuredHelperPort() -> UInt16 {
    if let raw = ProcessInfo.processInfo.environment["RONGTA_HELPER_PORT"],
       let value = UInt16(raw), value != 0 {
        return value
    }
    return helperPort
}

/// Write one request, half-close, and read the reply. Does not open Bluetooth.
private func helperExchange(_ payload: Data, timeoutSeconds: Int) -> String? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 {
        return nil
    }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = configuredHelperPort().bigEndian
    _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
    var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    let tvLen = socklen_t(MemoryLayout<timeval>.size)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvLen)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvLen)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if connected != 0 {
        return nil
    }
    var sent = 0
    let bytes = [UInt8](payload)
    while sent < bytes.count {
        let n = bytes.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress! + sent, bytes.count - sent)
        }
        if n < 0 {
            if errno == EINTR { continue }
            return nil
        }
        if n == 0 { break }
        sent += n
    }
    // Half-close so the helper, which reads a PRINT body until EOF, finishes the job.
    shutdown(fd, SHUT_WR)
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while data.count < 1024 * 1024 {
        let n = read(fd, &buffer, buffer.count)
        if n == 0 { break }
        if n < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            break
        }
        data.append(buffer, count: n)
    }
    return String(data: data, encoding: .utf8) ?? ""
}

@main
enum RongtaBleMain {
    static func main() {
        _ = signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        let env = ProcessInfo.processInfo.environment

        if args.contains("--scan-client") {
            let reply = helperExchange(Data("SCAN\n".utf8), timeoutSeconds: 20) ?? ""
            FileHandle.standardOutput.write(Data(reply.utf8))
            exit(reply.isEmpty || reply.hasPrefix("ERR") ? 1 : 0)
        }

        if let flag = args.firstIndex(of: "--send"), flag + 1 < args.count {
            let uri = args[flag + 1]
            let path = flag + 2 < args.count ? args[flag + 2] : "-"
            guard let payload = readFile(path), !payload.isEmpty else {
                log("ERROR: empty or unreadable job")
                exit(1)
            }
            var request = Data("PRINT \(uri)\n".utf8)
            request.append(payload)
            let reply = helperExchange(request, timeoutSeconds: 180) ?? ""
            if !reply.isEmpty {
                FileHandle.standardOutput.write(Data(reply.utf8))
            }
            if reply.hasPrefix("OK") {
                exit(0)
            }
            fputs(reply.isEmpty ? "no reply\n" : reply, stderr)
            exit(1)
        }

        let app = BleApp()

        if args.contains("--helper") {
            DispatchQueue.global(qos: .userInitiated).async {
                app.serve()
            }
            dispatchMain()
        }

        if args.contains("--status") {
            // Creates a manager so the delegate can report the live authorization.
            // That prompts when the user has not chosen yet. Socket STATUS does not.
            DispatchQueue.main.async {
                app.statusCompletion = { manager in
                    let auth = BluetoothGate.Auth(manager.authorization)
                    let radio = BluetoothGate.Radio(manager.state)
                    let line = "authorization=\(auth.token) state=\(radio.token)\n"
                    FileHandle.standardOutput.write(line.data(using: .utf8)!)
                    let granted = manager.authorization == .allowedAlways && manager.state == .poweredOn
                    exit(granted ? 0 : 1)
                }
                app.replaceCentral()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    guard app.statusCompletion != nil else { return }
                    app.statusCompletion = nil
                    let auth = BluetoothGate.Auth(CBCentralManager.authorization)
                    let line = "authorization=\(auth.token) state=none\n"
                    FileHandle.standardError.write(line.data(using: .utf8)!)
                    exit(1)
                }
            }
            dispatchMain()
        }

        if args.contains("--scan") || args.contains("--scan-all") {
            app.listEverything = args.contains("--scan-all")
            DispatchQueue.main.async {
                app.startScan(seconds: 8) { text in
                    if text.hasPrefix("ERR") {
                        log(text.trimmingCharacters(in: .newlines))
                        exit(1)
                    }
                    FileHandle.standardOutput.write((text.isEmpty ? "" : text).data(using: .utf8)!)
                    exit(0)
                }
            }
            dispatchMain()
        }

        var uri = env["DEVICE_URI"] ?? "rongta-bt://auto"
        if let flag = args.firstIndex(of: "--uri"), flag + 1 < args.count {
            uri = args[flag + 1]
        }
        let path: String
        if args.count >= 7 {
            path = args[6]
        } else if let flag = args.firstIndex(of: "--uri"), flag + 2 < args.count {
            path = args[flag + 2]
        } else if args.count == 2 {
            path = args[1]
        } else if args.count == 1 {
            path = "-"
        } else {
            usage()
            exit(2)
        }
        guard let payload = readFile(path), !payload.isEmpty else {
            log("ERROR: empty or unreadable job")
            exit(1)
        }
        DispatchQueue.main.async {
            app.startPrint(uri: uri, payload: payload) { message in
                if message.hasPrefix("OK") {
                    exit(0)
                }
                log(message.trimmingCharacters(in: .newlines))
                exit(1)
            }
        }
        dispatchMain()
    }
}
