// SPDX-License-Identifier: GPL-3.0-or-later
// Queue, option, and calibration math for Rongta Label Setup.
// This file does not talk to CUPS. The app and the unit tests both use it.
import Foundation

enum PrinterLanguage: String, Hashable {
    case zpl
    case tspl
}

enum SetupSection: String, Hashable, CaseIterable, Identifiable {
    case printers
    case paper
    case calibrate
    case help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .printers: return "Printer"
        case .paper: return "Paper & Settings"
        case .calibrate: return "Calibrate"
        case .help: return "Help"
        }
    }

    var symbol: String {
        switch self {
        case .printers: return "printer"
        case .paper: return "doc.text"
        case .calibrate: return "ruler"
        case .help: return "questionmark.circle"
        }
    }
}

enum Transport: String, Hashable {
    case bluetooth
}

struct PrinterModel: Equatable, Identifiable {
    var id: String
    var menuTitle: String
    var ppdFile: String
    var language: PrinterLanguage

    static let catalog: [PrinterModel] = [
        PrinterModel(id: "RP420", menuTitle: "RP420", ppdFile: "Rongta_RP420_ZPL_203dpi.ppd", language: .zpl),
        PrinterModel(id: "RP421A", menuTitle: "RP421A", ppdFile: "Rongta_RP421A_ZPL_203dpi.ppd", language: .zpl),
        PrinterModel(id: "RP425", menuTitle: "RP425", ppdFile: "Rongta_RP425_ZPL_203dpi.ppd", language: .zpl),
        PrinterModel(id: "RP422", menuTitle: "RP422", ppdFile: "Rongta_RP422_TSPL_203dpi.ppd", language: .tspl),
        PrinterModel(id: "ZPL", menuTitle: "Other printer", ppdFile: "Rongta_ZPL_203dpi.ppd", language: .zpl),
        PrinterModel(id: "TSPL", menuTitle: "Other printer with a mark", ppdFile: "Rongta_TSPL_203dpi.ppd", language: .tspl),
    ]

    static func find(_ id: String) -> PrinterModel? {
        catalog.first { $0.id == id }
    }
}

struct LabelSize: Equatable, Identifiable {
    var id: String
    var title: String

    static let presets: [LabelSize] = [
        LabelSize(id: "4x6in", title: "4 x 6 in"),
        LabelSize(id: "4x4in", title: "4 x 4 in"),
        LabelSize(id: "4x3in", title: "4 x 3 in"),
        LabelSize(id: "4x2in", title: "4 x 2 in"),
        LabelSize(id: "4x1in", title: "4 x 1 in"),
        LabelSize(id: "4x5in", title: "4 x 5 in"),
        LabelSize(id: "4x6.5in", title: "4 x 6.5 in"),
        LabelSize(id: "4x13in", title: "4 x 13 in"),
        LabelSize(id: "3x3in", title: "3 x 3 in"),
        LabelSize(id: "3x2in", title: "3 x 2 in"),
        LabelSize(id: "3x1.25in", title: "3 x 1.25 in"),
        LabelSize(id: "3x1in", title: "3 x 1 in"),
        LabelSize(id: "2.25x1.25in", title: "2.25 x 1.25 in"),
        LabelSize(id: "2x1in", title: "2 x 1 in"),
        LabelSize(id: "100x150mm", title: "100 x 150 mm"),
    ]
}

struct DiscoveredDevice: Equatable, Identifiable {
    var uri: String
    var name: String
    var transport: Transport
    var rssi: Int = 0
    var matchesRongta: Bool = true
    var peripheralID: String = ""
    var id: String { uri }
}

struct QueueSummary: Equatable, Identifiable {
    var name: String
    var uri: String
    var language: PrinterLanguage
    var id: String { name }
}

struct QueueOptions: Equatable {
    var pageSize: String
    var usesCustom: Bool
    var customWidthInches: Double
    var customHeightInches: Double
    var mediaType: String
    var gapMm: Int
    var darkness: Int
    var speed: Int
    var dither: String
    var insetLeft: Int
    var insetRight: Int
    var insetTop: Int
    var insetBottom: Int
    var labelHomeX: Int
    var labelTop: Int
}

enum DriverPaths {
    static let ppdDirectory = "/Library/Printers/PPDs/Contents/Resources"
    static let ble = "/Library/Application Support/com.blankspeaker.rongta-label/rongta-ble"
    static let edgeTest = "/Library/Application Support/com.blankspeaker.rongta-label/edge-test.pdf"
    static let edgeTestDirectory = "/Library/Application Support/com.blankspeaker.rongta-label/edge-tests"
    static let uninstall = "/Library/Application Support/com.blankspeaker.rongta-label/uninstall.sh"
    static let lpadmin = "/usr/sbin/lpadmin"
    static let lp = "/usr/bin/lp"
    static let lpoptions = "/usr/bin/lpoptions"
    static let lpstat = "/usr/bin/lpstat"
    /// Opens the Bluetooth privacy list. The helper process is what scans and prints.
    static let bluetoothPrivacyURL = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Bluetooth"
}

enum SetupLogic {
    static let dotsPerMillimetre = 8.0
    static let testPrintProgress = "Printing your test label… this can take up to 30 seconds."
    static let testPrintWaitNote = "This can take up to 30 seconds."
    static let testPrintDone = "Done! Check your printer."
    static let projectPage = URL(string: "https://github.com/blankspeaker/Rongta-Label-BLE")!

    static func printersNeedAttention(_ text: String) -> Bool {
        text.lowercased().contains("disabled")
    }
    static let insetRange = 0...800
    static let homeRange = -800...800
    static let topRange = -120...120

    /// Install and a normal launch both open on Add printer.
    static func initialSection(queueCount: Int) -> SetupSection {
        _ = queueCount
        return .printers
    }

    /// Longest concrete model id contained in a BLE name. `RP425-ABCD` is RP425.
    static func modelID(matchingBLEName name: String) -> String? {
        let haystack = name.uppercased()
        let specific = PrinterModel.catalog.filter { $0.id != "ZPL" && $0.id != "TSPL" }
        for model in specific.sorted(by: { $0.id.count > $1.id.count }) {
            if haystack.contains(model.id.uppercased()) {
                return model.id
            }
        }
        return nil
    }

    /// How an installed queue is connected.
    static func connectionPhrase(for _: String) -> String {
        "Connected over Bluetooth"
    }

    /// One nearby printer, or the one that matches the queue, or the first result.
    /// A found printer should fill the name field.
    static func preferredDevice(_ devices: [DiscoveredDevice], matchingURI: String?) -> DiscoveredDevice? {
        if let only = soleDevice(devices) {
            return only
        }
        if let matchingURI, let match = devices.first(where: { $0.uri == matchingURI }) {
            return match
        }
        return devices.first
    }

    /// The only printer, after identical URIs are collapsed. Several printers means no guess.
    static func soleDevice(_ devices: [DiscoveredDevice]) -> DiscoveredDevice? {
        var unique: [DiscoveredDevice] = []
        for device in devices where !unique.contains(where: { $0.uri == device.uri }) {
            unique.append(device)
        }
        return unique.count == 1 ? unique[0] : nil
    }

    static func defaultOptions(language: PrinterLanguage) -> QueueOptions {
        let zpl = language == .zpl
        return QueueOptions(
            pageSize: "4x6in",
            usesCustom: false,
            customWidthInches: 4,
            customHeightInches: 6,
            mediaType: "Gap",
            gapMm: 2,
            darkness: 7,
            speed: 5,
            dither: "Threshold",
            insetLeft: zpl ? 8 : 0,
            insetRight: zpl ? 8 : 0,
            insetTop: zpl ? 32 : 0,
            insetBottom: 0,
            labelHomeX: 20,
            labelTop: -20
        )
    }

    /// Signed millimetres to dots. Positive is more inset. 0.5 mm is 4 dots.
    static func insetDots(forMillimetres mm: Double) -> Int {
        Int((mm * dotsPerMillimetre).rounded())
    }

    static func adjustedInset(current: Int, millimetres: Double) -> Int {
        let next = current + insetDots(forMillimetres: millimetres)
        return min(insetRange.upperBound, max(insetRange.lowerBound, next))
    }

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    static func applyAdjustments(
        _ current: QueueOptions,
        leftMM: Double,
        rightMM: Double,
        topMM: Double,
        bottomMM: Double
    ) -> QueueOptions {
        var next = current
        next.insetLeft = adjustedInset(current: current.insetLeft, millimetres: leftMM)
        next.insetRight = adjustedInset(current: current.insetRight, millimetres: rightMM)
        next.insetTop = adjustedInset(current: current.insetTop, millimetres: topMM)
        next.insetBottom = adjustedInset(current: current.insetBottom, millimetres: bottomMM)
        next.labelHomeX = clamp(next.labelHomeX, to: homeRange)
        next.labelTop = clamp(next.labelTop, to: topRange)
        return next
    }

    static func language(ofPPD text: String) -> PrinterLanguage? {
        if text.contains("rastertotspl-rt") {
            return .tspl
        }
        if text.contains("rastertozpl-rt") {
            return .zpl
        }
        return nil
    }

    static func queueUsesDriver(ppdText: String?, ppdPath: String?, deviceURI: String) -> Bool {
        if let ppdText, language(ofPPD: ppdText) != nil {
            return true
        }
        if let ppdPath, ppdPath.contains("Rongta_") && ppdPath.contains("_203dpi.ppd") {
            return true
        }
        return deviceURI.hasPrefix("rongta-bt://")
    }

    static func parseLpstatDevices(_ text: String) -> [String: String] {
        var devices: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let prefix = "device for "
            guard line.hasPrefix(prefix), let colon = line.range(of: ": ") else {
                continue
            }
            let name = String(line[line.index(line.startIndex, offsetBy: prefix.count)..<colon.lowerBound])
            let uri = String(line[colon.upperBound...])
            if !name.isEmpty && !uri.isEmpty {
                devices[name] = uri
            }
        }
        return devices
    }

    /// `lpstat` and `lpoptions` exit non-zero when the Mac has no printers.
    /// That is an empty list, not a failure.
    static func isBenignCupsFailure(status: Int32, stdout: String, stderr: String) -> Bool {
        if status == 0 {
            return false
        }
        let blob = (stdout + "\n" + stderr).lowercased()
        let markers = [
            "no destinations",
            "unknown printer",
            "unknown destination",
            "destination not found",
        ]
        return markers.contains { blob.contains($0) }
    }

    struct ScanExplanation: Equatable {
        var message: String
        var detail: String
        var openBluetoothSettings: Bool
    }

    /// Friendly text for a failed `rongta-ble --scan`. The raw status stays in `detail`.
    static func explainBluetoothScan(status: Int32, stdout: String, stderr: String) -> ScanExplanation {
        let blob = stdout + "\n" + stderr
        let lower = blob.lowercased()
        let detail = commandDetail(status: status, stdout: stdout, stderr: stderr)
        if lower.contains("bluetooth is off") || lower.contains("powered off") {
            return ScanExplanation(
                message: "Turn Bluetooth on. Searching will continue.",
                detail: detail,
                openBluetoothSettings: false
            )
        }
        if lower.contains("unsupported") {
            return ScanExplanation(
                message: "This Mac does not have Bluetooth.",
                detail: detail,
                openBluetoothSettings: false
            )
        }
        if status == 6 || lower.contains("permission") || lower.contains("not authorized")
            || lower.contains("unauthorized") || lower.contains("denied") {
            return ScanExplanation(
                message: "Allow Bluetooth for Rongta Label Setup in System Settings → Privacy & Security → Bluetooth. If the list says rongta-ble, allow that. It is the program that scans and prints.",
                detail: detail,
                openBluetoothSettings: true
            )
        }
        return ScanExplanation(
            message: "",
            detail: detail,
            openBluetoothSettings: false
        )
    }

    static func commandDetail(status: Int32, stdout: String, stderr: String) -> String {
        var lines: [String] = []
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty {
            lines.append(err)
        }
        if !out.isEmpty && out != err {
            lines.append(out)
        }
        lines.append("Exit code \(status).")
        return lines.joined(separator: "\n")
    }

    static func parseLpoptionsList(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let head = line[..<colon]
            let keyword = head.split(separator: "/").first.map(String.init) ?? ""
            guard !keyword.isEmpty else {
                continue
            }
            let tail = line[line.index(after: colon)...]
            let tokens = tail.split(whereSeparator: \.isWhitespace).map(String.init)
            if let starred = tokens.first(where: { $0.hasPrefix("*") && $0.count > 1 }) {
                values[keyword] = String(starred.dropFirst())
            }
        }
        return values
    }

    static func queueOptions(from values: [String: String], language: PrinterLanguage) -> QueueOptions {
        let base = defaultOptions(language: language)
        let page = values["PageSize"] ?? base.pageSize
        var options = base
        options.pageSize = page
        options.usesCustom = page.hasPrefix("Custom.")
        if let size = parseCustomInches(page) {
            options.customWidthInches = size.0
            options.customHeightInches = size.1
        }
        options.mediaType = values["MediaType"] ?? base.mediaType
        options.gapMm = intValue(values["rtGapMm"], default: base.gapMm, range: 0...10)
        options.darkness = intValue(values["Darkness"], default: base.darkness, range: 0...15)
        options.speed = intValue(values["PrintSpeed"], default: base.speed, range: 2...6)
        options.dither = values["rtDither"] ?? base.dither
        options.insetLeft = intValue(values["rtInsetLeft"], default: base.insetLeft, range: insetRange)
        options.insetRight = intValue(values["rtInsetRight"], default: base.insetRight, range: insetRange)
        options.insetTop = intValue(values["rtInsetTop"], default: base.insetTop, range: insetRange)
        options.insetBottom = intValue(values["rtInsetBottom"], default: base.insetBottom, range: insetRange)
        options.labelHomeX = intValue(values["rtLabelHomeX"], default: base.labelHomeX, range: homeRange)
        options.labelTop = intValue(values["rtLabelTop"], default: base.labelTop, range: topRange)
        return options
    }

    static func parseBleScan(_ stdout: String) -> [DiscoveredDevice] {
        // A trailing END block is the helper's final snapshot. Live lines before it are stale.
        let snapshot: String
        if let range = stdout.range(of: "\nEND\n", options: .backwards) {
            snapshot = String(stdout[range.upperBound...])
        } else if stdout.hasPrefix("END\n") {
            snapshot = String(stdout.dropFirst(4))
        } else {
            snapshot = stdout
        }
        var ordered: [String] = []
        var byURI: [String: DiscoveredDevice] = [:]
        for raw in snapshot.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, parts[0] == "DEV" else {
                continue
            }
            let uri = parts[1]
            guard uri.hasPrefix("rongta-bt://") else {
                continue
            }
            let name = parts.count >= 3 && !parts[2].isEmpty ? parts[2] : uri
            let rssi = parts.count >= 4 ? Int(parts[3]) ?? 0 : 0
            let matchesRongta = parts.count < 5 || parts[4] != "other"
            let peripheralID = parts.count >= 6 ? parts[5] : ""
            let device = DiscoveredDevice(
                uri: uri,
                name: name,
                transport: .bluetooth,
                rssi: rssi,
                matchesRongta: matchesRongta,
                peripheralID: peripheralID
            )
            if byURI[uri] == nil {
                ordered.append(uri)
            }
            byURI[uri] = device
        }
        return ordered.compactMap { byURI[$0] }
    }

    /// Same radio keeps one row. A peripheral id wins over the URI, which can change when a name arrives.
    static func deviceKey(_ device: DiscoveredDevice) -> String {
        if !device.peripheralID.isEmpty {
            return "ble:" + device.peripheralID.lowercased()
        }
        return "uri:" + device.uri
    }

    /// Fold new sightings into the list the sheet is already showing.
    /// A device that is missing from `updates` stays. An empty update leaves the list alone.
    /// New printers are inserted with the printers, sorted by name only at that moment.
    /// A signal change updates the row in place and does not move it.
    static func mergeDiscovered(_ existing: [DiscoveredDevice], with updates: [DiscoveredDevice]) -> [DiscoveredDevice] {
        if updates.isEmpty {
            return existing
        }
        var result = existing
        var indexByKey: [String: Int] = [:]
        for (index, device) in result.enumerated() {
            indexByKey[deviceKey(device)] = index
        }
        var newPrinters: [DiscoveredDevice] = []
        var newOthers: [DiscoveredDevice] = []
        var pendingKey: [String: Int] = [:]

        func apply(_ update: DiscoveredDevice, to device: inout DiscoveredDevice) {
            device.name = update.name
            device.rssi = update.rssi
            device.matchesRongta = update.matchesRongta
            if device.peripheralID.isEmpty {
                device.peripheralID = update.peripheralID
            }
        }

        for update in updates {
            let key = deviceKey(update)
            if let index = indexByKey[key] {
                apply(update, to: &result[index])
                continue
            }
            if let slot = pendingKey[key] {
                if slot >= 0 {
                    apply(update, to: &newPrinters[slot])
                } else {
                    apply(update, to: &newOthers[-slot - 1])
                }
                continue
            }
            if update.matchesRongta {
                pendingKey[key] = newPrinters.count
                newPrinters.append(update)
            } else {
                pendingKey[key] = -(newOthers.count + 1)
                newOthers.append(update)
            }
        }
        newPrinters.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if !newPrinters.isEmpty {
            let at = (result.lastIndex { $0.matchesRongta } ?? -1) + 1
            result.insert(contentsOf: newPrinters, at: at)
        }
        result.append(contentsOf: newOthers)
        return result
    }

    /// Four bars near the Mac, one bar when the advertiser is faint. Zero means unknown.
    static func signalBars(rssi: Int) -> Int {
        if rssi == 0 {
            return 0
        }
        if rssi >= -60 { return 4 }
        if rssi >= -70 { return 3 }
        if rssi >= -80 { return 2 }
        if rssi >= -90 { return 1 }
        return 1
    }

    static func isAlreadyAdded(_ device: DiscoveredDevice, queues: [QueueSummary]) -> Bool {
        for queue in queues {
            if queue.uri == device.uri {
                return true
            }
            if queue.name.caseInsensitiveCompare(device.name) == .orderedSame {
                return true
            }
            if let range = queue.uri.range(of: "://") {
                let rest = String(queue.uri[range.upperBound...]).removingPercentEncoding ?? ""
                if rest.caseInsensitiveCompare(device.name) == .orderedSame {
                    return true
                }
                if !device.peripheralID.isEmpty && rest.caseInsensitiveCompare(device.peripheralID) == .orderedSame {
                    return true
                }
            }
        }
        return false
    }

    static func friendlyPrintError(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("ff00") || lower.contains("ff02") || lower.contains("no compatible printer connection") {
            return incompatibleConnection
        }
        return text
    }

    static func sanitizeQueueName(_ raw: String) -> String {
        var name = ""
        for scalar in raw.unicodeScalars {
            let ch = Character(scalar)
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                name.append(ch)
            } else if ch == " " || ch == "." {
                name.append("_")
            }
        }
        while name.hasPrefix("_") || name.hasPrefix("-") {
            name.removeFirst()
        }
        if name.isEmpty {
            name = "Rongta"
        }
        if name.count > 127 {
            name = String(name.prefix(127))
        }
        return name
    }

    static func uniqueQueueName(_ base: String, existing: Set<String>) -> String {
        if !existing.contains(base) {
            return base
        }
        var number = 2
        while existing.contains("\(base)_\(number)") {
            number += 1
        }
        return "\(base)_\(number)"
    }

    static func customPageSize(widthInches: Double, heightInches: Double) -> String {
        "Custom.\(formatInches(widthInches))x\(formatInches(heightInches))in"
    }

    static func parseCustomInches(_ pageSize: String) -> (Double, Double)? {
        guard pageSize.hasPrefix("Custom.") else {
            return nil
        }
        var body = String(pageSize.dropFirst("Custom.".count))
        if body.hasSuffix("in") {
            body = String(body.dropLast(2))
        } else {
            return nil
        }
        let parts = body.split(separator: "x", maxSplits: 1).map(String.init)
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else {
            return nil
        }
        return (width, height)
    }

    static func customSizeError(widthInches: Double, heightInches: Double) -> String? {
        if widthInches < 1 || widthInches > 4.5 {
            return "Width must be 1 to 4.5 inches."
        }
        if heightInches < 0.5 || heightInches > 20 {
            return "Height must be 0.5 to 20 inches."
        }
        return nil
    }

    static func resolvedPageSize(_ options: QueueOptions) -> String {
        if options.usesCustom {
            return customPageSize(widthInches: options.customWidthInches, heightInches: options.customHeightInches)
        }
        return options.pageSize
    }

    static func lpadminAddArguments(queue: String, uri: String, ppdPath: String, description: String, pageSize: String) -> [String] {
        [
            DriverPaths.lpadmin, "-p", queue, "-E", "-v", uri, "-P", ppdPath, "-D", description,
            "-o", "PageSize=\(pageSize)",
        ]
    }

    static func lpadminSetDefaultArguments(queue: String) -> [String] {
        [DriverPaths.lpadmin, "-d", queue]
    }

    /// Create the queue, set the system default, then accept jobs.
    /// The console user's default is `lpoptions -d`, run outside this script.
    static func addPrinterShellCommand(queue: String, uri: String, ppdPath: String, description: String, pageSize: String) -> String {
        let add = lpadminShellCommand(lpadminAddArguments(
            queue: queue, uri: uri, ppdPath: ppdPath, description: description, pageSize: pageSize
        ))
        let makeDefault = lpadminShellCommand(lpadminSetDefaultArguments(queue: queue))
        return "\(add) && \(makeDefault) && \(enableQueueShellCommand(queue: queue))"
    }

    static func enableQueueShellCommand(queue: String) -> String {
        let quoted = shellSingleQuote(queue)
        return "/usr/sbin/cupsenable \(quoted) && /usr/sbin/cupsaccept \(quoted)"
    }

    /// User default. `lpadmin -d` as root does not set this, so `lpstat -d` stays empty.
    static func userDefaultArguments(queue: String) -> [String] {
        ["/usr/bin/lpoptions", "-d", queue]
    }

    static func lpadminSetArguments(queue: String, pairs: [(String, String)]) -> [String] {
        var args = [DriverPaths.lpadmin, "-p", queue]
        for pair in pairs {
            args.append("-o")
            args.append("\(pair.0)=\(pair.1)")
        }
        return args
    }

    static func paperOptionPairs(_ options: QueueOptions) -> [(String, String)] {
        [
            ("PageSize", resolvedPageSize(options)),
            ("MediaType", options.mediaType),
            ("rtGapMm", String(clamp(options.gapMm, to: 0...10))),
            ("Darkness", String(clamp(options.darkness, to: 0...15))),
            ("PrintSpeed", String(clamp(options.speed, to: 2...6))),
            ("rtDither", options.dither),
        ]
    }

    static func calibrationPairs(_ options: QueueOptions) -> [(String, String)] {
        let clamped = applyAdjustments(options, leftMM: 0, rightMM: 0, topMM: 0, bottomMM: 0)
        return [
            ("rtInsetLeft", String(clamped.insetLeft)),
            ("rtInsetRight", String(clamped.insetRight)),
            ("rtInsetTop", String(clamped.insetTop)),
            ("rtInsetBottom", String(clamped.insetBottom)),
            ("rtLabelHomeX", String(clamped.labelHomeX)),
            ("rtLabelTop", String(clamped.labelTop)),
        ]
    }

    static func lpEdgeTestArguments(queue: String, pageSize: String, pdfPath: String) -> [String] {
        [DriverPaths.lp, "-d", queue, "-o", "PageSize=\(pageSize)", pdfPath]
    }

    /// Installed PDF name for a PPD size. Custom sizes and path tricks return nil.
    static func edgeTestFilename(pageSize: String) -> String? {
        if pageSize.isEmpty || pageSize == "." || pageSize == ".." || pageSize.contains("..")
            || pageSize.hasPrefix("Custom.") || pageSize.contains("/") {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.x")
        if pageSize.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return nil
        }
        return "\(pageSize).pdf"
    }

    static func watchPrinterArguments(queue: String) -> [String] {
        [DriverPaths.lpstat, "-l", "-p", queue]
    }

    static func watchJobsArguments(queue: String, completed: Bool) -> [String] {
        [DriverPaths.lpstat, "-l", "-W", completed ? "completed" : "not-completed", "-o", queue]
    }

    /// `request id is Labels-23 (1 file(s))`
    static func parseJobID(_ text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let prefix = "request id is "
            guard line.hasPrefix(prefix) else {
                continue
            }
            let rest = line.dropFirst(prefix.count)
            let id = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if !id.isEmpty {
                return id
            }
        }
        return nil
    }

    enum PrintWatch: Equatable {
        case pending
        case succeeded
        case failed(String)
    }

    /// Disabled or aborted is a failure. A job that has not shown up yet is still pending.
    static func interpretPrintState(
        printerText: String,
        pendingJobs: String,
        completedJobs: String,
        jobID: String
    ) -> PrintWatch {
        if let reason = disabledReason(printerText) {
            return .failed(reason)
        }
        if let pending = jobRecord(in: pendingJobs, jobID: jobID) {
            if let reason = jobFailure(pending) {
                return .failed(reason)
            }
            return .pending
        }
        if let done = jobRecord(in: completedJobs, jobID: jobID) {
            if let reason = jobFailure(done) {
                return .failed(reason)
            }
            return .succeeded
        }
        return .pending
    }

    private static func disabledReason(_ text: String) -> String? {
        var sawDisabled = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if !sawDisabled {
                if line.lowercased().contains("disabled") {
                    sawDisabled = true
                }
                continue
            }
            if line.hasPrefix("\t") || line.hasPrefix(" ") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !isLpstatField(trimmed) {
                    return trimmed
                }
                continue
            }
            break
        }
        return sawDisabled ? "The printer is disabled." : nil
    }

    private static func isLpstatField(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else {
            return false
        }
        let key = line[..<colon]
        return !key.isEmpty && key.count < 40 && key.allSatisfy { $0.isLetter || $0 == " " }
    }

    private static func jobRecord(in text: String, jobID: String) -> String? {
        var capturing = false
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("\t") || (line.hasPrefix(" ") && capturing) {
                if capturing {
                    lines.append(line)
                }
                continue
            }
            if capturing {
                break
            }
            let token = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if token == jobID {
                capturing = true
                lines.append(line)
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func jobFailure(_ record: String) -> String? {
        let lower = record.lowercased()
        let failed = lower.contains("aborted") || lower.contains("canceled") || lower.contains("cancelled")
            || lower.contains("job-completed-with-errors")
        if !failed {
            return nil
        }
        for raw in record.split(separator: "\n").dropFirst() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "The test label did not print."
    }

    struct FittedFrame: Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    /// Enlarge a saved window that is smaller than the pages, then keep it inside the visible screen.
    static func fittedWindowFrame(
        current: FittedFrame,
        minimumWidth: Double,
        minimumHeight: Double,
        visible: FittedFrame
    ) -> FittedFrame {
        let cappedW = min(minimumWidth, visible.width)
        let cappedH = min(minimumHeight, visible.height)
        var frame = current
        if frame.width < cappedW { frame.width = cappedW }
        if frame.height < cappedH { frame.height = cappedH }
        if frame.width > visible.width { frame.width = visible.width }
        if frame.height > visible.height { frame.height = visible.height }
        if frame.x < visible.x { frame.x = visible.x }
        if frame.x + frame.width > visible.x + visible.width {
            frame.x = visible.x + visible.width - frame.width
        }
        if frame.y < visible.y { frame.y = visible.y }
        if frame.y + frame.height > visible.y + visible.height {
            frame.y = visible.y + visible.height - frame.height
        }
        return frame
    }

    static let helperLabel = "com.blankspeaker.rongta-label"
    static let helperScanLine = "SCAN"
    static let helperScanAllLine = "SCAN ALL"
    /// One session for the whole Add Printer sheet. The checkbox only filters what is already found.
    static let helperWatchLine = "WATCH ALL"
    static let helperStatusLine = "STATUS"
    static let incompatibleConnection = "This device has no compatible printer connection. Rongta Label Setup looks for service FF00 and writable characteristic FF02."

    static func kickstartArguments(uid: UInt32) -> [String] {
        ["/bin/launchctl", "kickstart", "gui/\(uid)/\(helperLabel)"]
    }

    struct HelperReply: Equatable {
        var devices: [DiscoveredDevice]
        var ok: Bool
        var needsPermission: Bool
        var message: String
    }

    static func parseHelperReply(_ text: String) -> HelperReply {
        let devices = parseBleScan(text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let needsPermission = lower.contains("permission") || lower.contains("not authorized")
            || lower.contains("unauthorized") || lower.contains("denied")
        if lower.hasPrefix("err") || lower.contains("\nerr ") {
            return HelperReply(devices: devices, ok: false, needsPermission: needsPermission, message: trimmed)
        }
        let ok = lower == "ok" || lower.hasPrefix("ok ") || lower.hasSuffix("\nok") || lower.hasSuffix("ok")
        return HelperReply(devices: devices, ok: ok, needsPermission: false, message: trimmed)
    }

    static func helperIsUnreachable(_ stderr: String) -> Bool {
        stderr.contains("Could not reach the Bluetooth helper.")
    }

    /// Direct spawn is only the fallback. The normal scan is the helper socket.
    static func bleScanArguments(helperPath: String) -> [String] {
        [helperPath, "--scan"]
    }

    static func lpoptionsArguments(queue: String) -> [String] {
        [DriverPaths.lpoptions, "-p", queue, "-l"]
    }

    static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func lpadminShellCommand(_ arguments: [String]) -> String {
        arguments.map(shellSingleQuote).joined(separator: " ")
    }

    static func administratorAppleScript(shellCommand: String) -> String {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    static func ppdPath(for model: PrinterModel, directory: String = DriverPaths.ppdDirectory) -> String {
        (directory as NSString).appendingPathComponent(model.ppdFile)
    }

    private static func intValue(_ text: String?, default fallback: Int, range: ClosedRange<Int>) -> Int {
        guard let text, let value = Int(text) else {
            return fallback
        }
        return clamp(value, to: range)
    }

    static func formatInches(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }
}
