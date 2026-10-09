// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

struct CommandResult: Equatable {
    var status: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { status == 0 }

    var errorText: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty {
            return err
        }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty {
            return out
        }
        return "Command failed (\(status))."
    }

    var canceled: Bool {
        let blob = (stderr + stdout).lowercased()
        return blob.contains("user canceled") || blob.contains("user cancelled") || blob.contains("(-128)")
    }
}

func runSync(_ arguments: [String]) -> CommandResult {
    guard let executable = arguments.first else {
        return CommandResult(status: 1, stdout: "", stderr: "Missing command.")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(arguments.dropFirst())
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
        try process.run()
    } catch {
        return CommandResult(status: 1, stdout: "", stderr: error.localizedDescription)
    }
    process.waitUntilExit()
    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    var stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if process.terminationReason == .uncaughtSignal {
        stderr += "\nStopped by signal \(process.terminationStatus)."
    }
    return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var section: SetupSection = .printers
    @Published var queues: [QueueSummary] = []
    @Published var selectedQueue: String?
    @Published var options = SetupLogic.defaultOptions(language: .zpl)
    @Published var language: PrinterLanguage = .zpl
    @Published var devices: [DiscoveredDevice] = []
    @Published var selectedDeviceURI: String?
    @Published var queueName = ""
    @Published var modelID = "RP425"
    @Published var nameTouched = false
    @Published var deltaLeft = 0.0
    @Published var deltaRight = 0.0
    @Published var deltaTop = 0.0
    @Published var deltaBottom = 0.0
    @Published var busy = false
    @Published var isPrinting = false
    @Published var needsAttention = false
    @Published var status = ""
    @Published var errorMessage: String?

    var health: StatusKind {
        if isPrinting {
            return .printing
        }
        if needsAttention {
            return .attention
        }
        if selectedQueue == nil {
            return .setup
        }
        return .ready
    }
    @Published var offerTestPrint = false
    @Published var confirmUninstall = false
    @Published var addingPrinter = false
    @Published var showAllBluetooth = false
    @Published var scanning = false
    @Published var scanMessage = ""
    private var userPickedDevice = false
    private var statusClearGeneration = 0
    @Published var scanDetail = ""
    @Published var showBluetoothSettings = false
    private var watchGeneration = 0
    private var watchSession: WatchSession?

    var selectedModel: PrinterModel {
        PrinterModel.find(modelID) ?? PrinterModel.catalog[2]
    }

    var selectedQueueSummary: QueueSummary? {
        queues.first { $0.name == selectedQueue }
    }

    func bootstrap() async {
        await refreshQueues()
        section = SetupLogic.initialSection(queueCount: queues.count)
        if let name = queues.first?.name {
            selectedQueue = name
            syncModelFromQueue()
            await loadOptions()
        }
        if queues.isEmpty {
            startPrinterWatch()
        }
    }

    func refreshQueues() async {
        let listed = await run([DriverPaths.lpstat, "-v"])
        if !listed.succeeded && !SetupLogic.isBenignCupsFailure(
            status: listed.status, stdout: listed.stdout, stderr: listed.stderr
        ) && listed.stdout.isEmpty {
            present(listed)
        }
        let devices = SetupLogic.parseLpstatDevices(listed.stdout)
        var found: [QueueSummary] = []
        for name in devices.keys.sorted() {
            let uri = devices[name] ?? ""
            let ppdPath = "/etc/cups/ppd/\(name).ppd"
            let text = (try? String(contentsOfFile: ppdPath, encoding: .utf8))
                ?? (try? String(contentsOfFile: "/private\(ppdPath)", encoding: .utf8))
            guard SetupLogic.queueUsesDriver(ppdText: text, ppdPath: ppdPath, deviceURI: uri) else {
                continue
            }
            let language = text.flatMap(SetupLogic.language(ofPPD:)) ?? .zpl
            found.append(QueueSummary(name: name, uri: uri, language: language))
        }
        queues = found
        if found.isEmpty {
            needsAttention = false
        } else if !isPrinting {
            let state = await run([DriverPaths.lpstat, "-p"])
            needsAttention = SetupLogic.printersNeedAttention(state.stdout)
        }
        if let selectedQueue, !found.contains(where: { $0.name == selectedQueue }) {
            self.selectedQueue = found.first?.name
        } else if selectedQueue == nil {
            selectedQueue = found.first?.name
        }
        syncModelFromQueue()
    }

    func syncModelFromQueue() {
        guard let name = selectedQueue else {
            return
        }
        if let id = SetupLogic.modelID(matchingBLEName: name) {
            modelID = id
        }
    }

    func beginAddingPrinter() {
        addingPrinter = true
        userPickedDevice = false
        nameTouched = false
        queueName = ""
        scanMessage = ""
        scanDetail = ""
        showBluetoothSettings = false
        dismissPrintResult()
        devices = []
        selectedDeviceURI = nil
        rescan()
    }

    /// Drops every row and starts one fresh scan. This is the only clear besides opening the sheet.
    func restartSearch() {
        devices = []
        selectedDeviceURI = nil
        userPickedDevice = false
        scanMessage = ""
        scanDetail = ""
        showBluetoothSettings = false
        if !nameTouched {
            queueName = ""
        }
        rescan()
    }

    /// Stops Bluetooth discovery when the user leaves the add-printer page, and resumes it without clearing when they come back.
    func syncPrinterWatch() {
        let wanted = section == .printers && (selectedQueue == nil || addingPrinter)
        if wanted {
            if watchSession == nil {
                startPrinterWatch()
            }
        } else if watchSession != nil || scanning {
            stopPrinterWatch()
        }
    }

    func keepCurrentPrinter() {
        addingPrinter = false
        stopPrinterWatch()
        scanning = false
        scanMessage = ""
        scanDetail = ""
        showBluetoothSettings = false
    }

    func dismissPrintResult() {
        guard status == SetupLogic.testPrintDone else {
            return
        }
        status = ""
        statusClearGeneration += 1
    }

    private func schedulePrintResultClear() {
        statusClearGeneration += 1
        let generation = statusClearGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if generation == self.statusClearGeneration && self.status == SetupLogic.testPrintDone {
                self.status = ""
            }
        }
    }

    func loadOptions() async {
        guard let name = selectedQueue else {
            return
        }
        language = selectedQueueSummary?.language ?? .zpl
        let result = await run(SetupLogic.lpoptionsArguments(queue: name))
        if !result.succeeded {
            if SetupLogic.isBenignCupsFailure(status: result.status, stdout: result.stdout, stderr: result.stderr) {
                return
            }
            present(result)
            return
        }
        options = SetupLogic.queueOptions(from: SetupLogic.parseLpoptionsList(result.stdout), language: language)
        deltaLeft = 0
        deltaRight = 0
        deltaTop = 0
        deltaBottom = 0
    }

    func rescan() {
        startPrinterWatch()
    }

    func startPrinterWatch() {
        watchGeneration += 1
        watchSession?.cancel()
        let session = WatchSession()
        watchSession = session
        let generation = watchGeneration
        scanning = true
        scanMessage = ""
        Task { await self.watchForPrinter(generation, session: session) }
    }

    func stopPrinterWatch() {
        watchGeneration += 1
        watchSession?.cancel()
        watchSession = nil
        scanning = false
    }

    /// One WATCH for as long as the sheet is open. It does not restart itself.
    private func watchForPrinter(_ generation: Int, session: WatchSession) async {
        scanning = true
        scanMessage = ""
        var active = session
        var outcome = await streamWatch(active)
        if generation != watchGeneration {
            return
        }
        if SetupLogic.helperIsUnreachable(outcome.stderr) {
            _ = await run(SetupLogic.kickstartArguments(uid: getuid()))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if generation != watchGeneration {
                return
            }
            let retry = WatchSession()
            active = retry
            watchSession = retry
            outcome = await streamWatch(active)
        }
        if generation != watchGeneration {
            return
        }
        if SetupLogic.helperIsUnreachable(outcome.stderr) {
            let path = DriverPaths.ble
            let spawned = await Task.detached(priority: .userInitiated) {
                DisclaimedSpawn.scan(path: path)
            }.value
            let reply = SetupLogic.parseHelperReply(spawned.stdout.isEmpty ? spawned.stderr : spawned.stdout)
            if !reply.devices.isEmpty {
                noteScanProgress(reply.devices)
            }
            outcome = spawned
        }
        if generation != watchGeneration {
            return
        }
        scanning = false
        if watchSession === active {
            watchSession = nil
        }
        if !devices.isEmpty {
            scanMessage = ""
            scanDetail = ""
            showBluetoothSettings = false
            return
        }
        let reply = SetupLogic.parseHelperReply(outcome.stdout.isEmpty ? outcome.stderr : outcome.stdout)
        if reply.needsPermission {
            outcome = CommandResult(status: 1, stdout: outcome.stdout, stderr: reply.message)
        }
        applyDiscovery(outcome)
    }

    private func streamWatch(_ session: WatchSession) async -> CommandResult {
        let line = SetupLogic.helperWatchLine
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = HelperSocket.exchangeWatch(line: line, session: session) { text in
                    let parsed = SetupLogic.parseBleScan(text)
                    Task { @MainActor in
                        self.noteScanProgress(parsed)
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    func noteScanProgress(_ found: [DiscoveredDevice]) {
        guard !found.isEmpty else {
            return
        }
        devices = SetupLogic.mergeDiscovered(devices, with: found)
        guard selectedDeviceURI == nil, !userPickedDevice else {
            return
        }
        let printers = devices.filter(\.matchesRongta)
        if printers.count == 1, let only = printers.first {
            chooseDevice(only)
        }
    }

    private func applyDiscovery(_ result: CommandResult) {
        if !devices.isEmpty {
            if selectedDeviceURI == nil && devices.count == 1, let only = devices.first {
                chooseDevice(only)
            }
            scanMessage = ""
            scanDetail = ""
            showBluetoothSettings = false
            return
        }
        if let uri = selectedDeviceURI, !devices.contains(where: { $0.uri == uri }) {
            selectedDeviceURI = nil
        }
        if devices.isEmpty && !result.succeeded {
            let explained = SetupLogic.explainBluetoothScan(
                status: result.status, stdout: result.stdout, stderr: result.stderr
            )
            scanMessage = explained.message
            scanDetail = explained.detail
            showBluetoothSettings = explained.openBluetoothSettings
            return
        }
        scanMessage = ""
        scanDetail = ""
        showBluetoothSettings = false
    }

    func openBluetoothSettings() {
        _ = runSync([ "/usr/bin/open", DriverPaths.bluetoothPrivacyURL ])
    }

    func chooseDevice(_ device: DiscoveredDevice, userPick: Bool = false) {
        if userPick {
            userPickedDevice = true
        }
        selectedDeviceURI = device.uri
        if let id = SetupLogic.modelID(matchingBLEName: device.name) {
            modelID = id
        }
        if !nameTouched || queueName.isEmpty {
            let base = SetupLogic.sanitizeQueueName(device.name)
            queueName = SetupLogic.uniqueQueueName(base, existing: Set(queues.map(\.name)))
        }
    }

    func addPrinter() async {
        guard let uri = selectedDeviceURI else {
            errorMessage = "Choose a printer first."
            return
        }
        let name = SetupLogic.sanitizeQueueName(queueName)
        queueName = name
        let model = selectedModel
        let ppd = SetupLogic.ppdPath(for: model)
        guard FileManager.default.fileExists(atPath: ppd) else {
            errorMessage = "That printer model is not available. Install Rongta-Label-BLE again."
            return
        }
        let shell = SetupLogic.addPrinterShellCommand(
            queue: name,
            uri: uri,
            ppdPath: ppd,
            description: "Rongta \(model.menuTitle)",
            pageSize: "4x6in"
        )
        await commitShell(shell, success: "\(name) was added.") {
            let userDefault = await self.run(SetupLogic.userDefaultArguments(queue: name))
            self.selectedQueue = name
            self.addingPrinter = false
            self.stopPrinterWatch()
            self.scanning = false
            self.scanMessage = ""
            await self.refreshQueues()
            await self.loadOptions()
            if userDefault.succeeded {
                self.status = "\(name) is the default printer."
                self.offerTestPrint = true
            } else {
                self.status = ""
                self.errorMessage = userDefault.errorText
            }
        }
    }

    func enableQueue() async {
        guard let name = selectedQueue else {
            errorMessage = "Add a printer first."
            return
        }
        await commitShell(SetupLogic.enableQueueShellCommand(queue: name), success: "\(name) is ready to print.") {
            self.needsAttention = false
            await self.refreshQueues()
        }
    }

    func uninstall() async {
        guard FileManager.default.fileExists(atPath: DriverPaths.uninstall) else {
            errorMessage = "The uninstaller is not available. Install Rongta-Label-BLE again."
            return
        }
        let shell = SetupLogic.lpadminShellCommand([DriverPaths.uninstall])
        await commitShell(shell, success: "Rongta Label Setup was removed.") {}
    }

    func savePaper() async {
        guard let name = selectedQueue else {
            errorMessage = "Add a printer first."
            return
        }
        if options.usesCustom, let problem = SetupLogic.customSizeError(
            widthInches: options.customWidthInches,
            heightInches: options.customHeightInches
        ) {
            errorMessage = problem
            return
        }
        let args = SetupLogic.lpadminSetArguments(queue: name, pairs: SetupLogic.paperOptionPairs(options))
        await commit(args, success: "Saved paper settings for \(name).") {
            await self.loadOptions()
        }
    }

    func saveCalibration() async {
        guard let name = selectedQueue else {
            errorMessage = "Add a printer first."
            return
        }
        let next = SetupLogic.applyAdjustments(
            options,
            leftMM: deltaLeft,
            rightMM: deltaRight,
            topMM: deltaTop,
            bottomMM: deltaBottom
        )
        let args = SetupLogic.lpadminSetArguments(queue: name, pairs: SetupLogic.calibrationPairs(next))
        await commit(args, success: "Saved calibration for \(name).") {
            await self.loadOptions()
        }
    }

    func resetCalibration() async {
        guard let name = selectedQueue else {
            errorMessage = "Add a printer first."
            return
        }
        let defaults = SetupLogic.defaultOptions(language: language)
        let args = SetupLogic.lpadminSetArguments(queue: name, pairs: SetupLogic.calibrationPairs(defaults))
        await commit(args, success: "Restored calibration defaults for \(name).") {
            await self.loadOptions()
        }
    }

    func printEdgeTest() async {
        guard let name = selectedQueue else {
            errorMessage = "Add a printer first."
            return
        }
        let pageSize = SetupLogic.resolvedPageSize(options)
        guard let prepared = prepareEdgeTest(pageSize: pageSize) else {
            errorMessage = "The test label is not available. Install Rongta-Label-BLE again."
            return
        }
        await perform {
            defer {
                if prepared.temporary {
                    try? FileManager.default.removeItem(atPath: prepared.path)
                }
            }
            self.isPrinting = true
            self.status = SetupLogic.testPrintProgress
            let result = await self.run(SetupLogic.lpEdgeTestArguments(
                queue: name, pageSize: prepared.printSize, pdfPath: prepared.path
            ))
            guard result.succeeded, let jobID = SetupLogic.parseJobID(result.stdout) else {
                self.isPrinting = false
                self.needsAttention = true
                self.status = ""
                self.errorMessage = result.succeeded
                    ? "The printer did not accept the test label."
                    : SetupLogic.friendlyPrintError(result.errorText)
                return
            }
            let deadline = Date().addingTimeInterval(60)
            while true {
                let printer = await self.run(SetupLogic.watchPrinterArguments(queue: name))
                let pending = await self.run(SetupLogic.watchJobsArguments(queue: name, completed: false))
                let completed = await self.run(SetupLogic.watchJobsArguments(queue: name, completed: true))
                switch SetupLogic.interpretPrintState(
                    printerText: printer.stdout,
                    pendingJobs: pending.stdout,
                    completedJobs: completed.stdout,
                    jobID: jobID
                ) {
                case .succeeded:
                    self.isPrinting = false
                    self.needsAttention = false
                    self.status = SetupLogic.testPrintDone
                    self.schedulePrintResultClear()
                    return
                case .failed(let message):
                    self.isPrinting = false
                    self.needsAttention = true
                    self.status = message
                    self.errorMessage = SetupLogic.friendlyPrintError(message)
                    return
                case .pending:
                    break
                }
                if Date() >= deadline {
                    self.isPrinting = false
                    self.needsAttention = true
                    self.status = ""
                    self.errorMessage = "The test label is still waiting."
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private struct PreparedEdgeTest {
        var path: String
        var printSize: String
        var temporary: Bool
        var fellBack: Bool
    }

    private func prepareEdgeTest(pageSize: String) -> PreparedEdgeTest? {
        if let file = SetupLogic.edgeTestFilename(pageSize: pageSize) {
            let named = (DriverPaths.edgeTestDirectory as NSString).appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: named) {
                return PreparedEdgeTest(path: named, printSize: pageSize, temporary: false, fellBack: false)
            }
        } else if let data = EdgeTestPDF.render(pageSize: pageSize) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("rongta-edge-\(UUID().uuidString).pdf")
            if (try? data.write(to: url)) != nil {
                return PreparedEdgeTest(path: url.path, printSize: pageSize, temporary: true, fellBack: false)
            }
        }
        guard FileManager.default.fileExists(atPath: DriverPaths.edgeTest) else {
            return nil
        }
        return PreparedEdgeTest(path: DriverPaths.edgeTest, printSize: "4x6in", temporary: false, fellBack: true)
    }

    var pendingInsets: QueueOptions {
        SetupLogic.applyAdjustments(
            options,
            leftMM: deltaLeft,
            rightMM: deltaRight,
            topMM: deltaTop,
            bottomMM: deltaBottom
        )
    }

    private func commit(_ arguments: [String], success: String, follow: @escaping () async -> Void) async {
        await commitShell(SetupLogic.lpadminShellCommand(arguments), success: success, follow: follow)
    }

    private func commitShell(_ shell: String, success: String, follow: @escaping () async -> Void) async {
        await perform {
            self.status = "Waiting for your password…"
            let script = SetupLogic.administratorAppleScript(shellCommand: shell)
            let result = await self.run(["/usr/bin/osascript", "-e", script])
            if result.canceled {
                self.status = "Canceled."
                return
            }
            if !result.succeeded {
                self.present(result)
                return
            }
            self.status = success
            await follow()
        }
    }

    private func present(_ result: CommandResult) {
        if result.canceled {
            status = "Canceled."
            return
        }
        status = ""
        errorMessage = result.errorText
    }

    private func perform(_ work: @escaping () async -> Void) async {
        if busy {
            return
        }
        busy = true
        await work()
        busy = false
    }

    private func run(_ arguments: [String]) async -> CommandResult {
        let args = arguments
        return await Task.detached(priority: .userInitiated) {
            runSync(args)
        }.value
    }

}
