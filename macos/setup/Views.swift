// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// Default window content size. Height is the measured Add Printer page, which is the tallest.
enum SetupWindow {
    static let contentWidth: CGFloat = 1040
    /// Tallest page is Add Printer. Measured fitting height is 874; a few points keep the last control off the edge.
    static let contentHeight: CGFloat = 880
}

private struct ShotActionsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Headless screenshots set this so primary buttons use the accent fill.
    /// An offscreen window is not key, and AppKit then draws those buttons gray.
    var shotActions: Bool {
        get { self[ShotActionsKey.self] }
        set { self[ShotActionsKey.self] = newValue }
    }
}

private struct AccentProminentStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isEnabled && !configuration.isPressed ? Color.accentColor : Color.accentColor.opacity(0.45))
            )
    }
}

private struct ProminentAction: ViewModifier {
    @Environment(\.shotActions) private var shotActions
    var large: Bool

    func body(content: Content) -> some View {
        if shotActions {
            content.buttonStyle(AccentProminentStyle()).controlSize(large ? .large : .regular)
        } else if large {
            content.buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    func prominentAction(large: Bool = true) -> some View {
        modifier(ProminentAction(large: large))
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SetupChrome(scrolls: true)
            .frame(
                minWidth: SetupWindow.contentWidth,
                idealWidth: SetupWindow.contentWidth,
                maxWidth: .infinity,
                minHeight: SetupWindow.contentHeight,
                idealHeight: SetupWindow.contentHeight,
                maxHeight: .infinity
            )
            .background(WindowFrameGuard())
            .alert("Could not finish", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Print a test label?", isPresented: $model.offerTestPrint) {
            Button("Print Test Label") { Task { await model.printEdgeTest() } }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(SetupLogic.testPrintWaitNote)
        }
        .onChange(of: model.section) { _ in
            model.dismissPrintResult()
            model.syncPrinterWatch()
        }
        .alert("Uninstall Rongta Label Setup?", isPresented: $model.confirmUninstall) {
            Button("Uninstall", role: .destructive) { Task { await model.uninstall() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the app and the printer driver from this Mac.")
        }
    }
}

/// The sidebar and the current page. `scrolls` wraps the page so a short screen scrolls instead of clipping.
struct SetupChrome: View {
    @EnvironmentObject private var model: AppModel
    var scrolls: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
            Divider()
            page
                .frame(maxWidth: .infinity, maxHeight: scrolls ? .infinity : nil, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: scrolls ? .infinity : nil, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var page: some View {
        if scrolls {
            ScrollView(.vertical) {
                pageColumn
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(.automatic, axes: .vertical)
        } else {
            pageColumn
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rongta Label Setup")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 8)
            ForEach(SetupSection.allCases) { section in
                sidebarRow(section)
            }
            if scrolls {
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .frame(width: 230, alignment: .topLeading)
        .frame(maxHeight: scrolls ? .infinity : nil, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sidebarRow(_ section: SetupSection) -> some View {
        Button {
            model.section = section
        } label: {
            Label(section.title, systemImage: section.symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(model.section == section ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }

    private var pageColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if model.isPrinting {
                printingBanner
            } else if model.status == SetupLogic.testPrintDone {
                doneBanner
            }
            Group {
                switch model.section {
                case .printers:
                    PrintersView()
                case .paper:
                    PaperView()
                case .calibrate:
                    CalibrateView()
                case .help:
                    HelpView()
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusPill(kind: model.health)
            Spacer()
            if model.needsAttention {
                Button("Turn printer back on") {
                    Task { await model.enableQueue() }
                }
                .disabled(model.busy)
            }
        }
    }

    private var printingBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(SetupLogic.testPrintProgress)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var doneBanner: some View {
        Text(SetupLogic.testPrintDone)
            .font(.body.weight(.semibold))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Keeps a restored window at least as large as the pages, and never larger than the visible screen.
struct WindowFrameGuard: NSViewRepresentable {
    @Environment(\.shotActions) private var shotActions
    @EnvironmentObject private var model: AppModel

    func makeNSView(context: Context) -> WindowFrameGuardView {
        let view = WindowFrameGuardView()
        view.shots = shotActions
        return view
    }

    func updateNSView(_ view: WindowFrameGuardView, context: Context) {
        view.shots = shotActions
        view.enforce()
        _ = model.addingPrinter
    }
}

final class WindowFrameGuardView: NSView {
    var shots = false
    private var adjusting = false
    private var observed = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !shots, window.frame.origin.x > -16000 else { return }
        if !observed {
            observed = true
            window.setFrameAutosaveName("RongtaLabelSetup")
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowChanged),
                name: NSWindow.didResizeNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowChanged),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
        }
        enforce()
    }

    @objc private func windowChanged() {
        enforce()
    }

    func enforce() {
        guard !shots, !adjusting, let window else { return }
        if window.frame.origin.x < -16000 { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let contentMin = NSSize(width: SetupWindow.contentWidth, height: SetupWindow.contentHeight)
        let minFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentMin)).size
        let fitted = SetupLogic.fittedWindowFrame(
            current: SetupLogic.FittedFrame(
                x: window.frame.origin.x,
                y: window.frame.origin.y,
                width: window.frame.width,
                height: window.frame.height
            ),
            minimumWidth: minFrame.width,
            minimumHeight: minFrame.height,
            visible: SetupLogic.FittedFrame(
                x: visible.origin.x,
                y: visible.origin.y,
                width: visible.width,
                height: visible.height
            )
        )
        let frame = NSRect(x: fitted.x, y: fitted.y, width: fitted.width, height: fitted.height)
        let capped = NSSize(
            width: min(minFrame.width, visible.width),
            height: min(minFrame.height, visible.height)
        )
        if window.minSize != capped {
            window.minSize = capped
        }
        guard abs(frame.width - window.frame.width) > 0.5
            || abs(frame.height - window.frame.height) > 0.5
            || abs(frame.origin.x - window.frame.origin.x) > 0.5
            || abs(frame.origin.y - window.frame.origin.y) > 0.5 else {
            return
        }
        adjusting = true
        window.setFrame(frame, display: true)
        adjusting = false
    }
}

enum StatusKind: Equatable {
    case setup
    case ready
    case printing
    case attention
}

struct StatusPill: View {
    var kind: StatusKind

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 9, height: 9)
            Text(title)
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.16), in: Capsule())
    }

    private var title: String {
        switch kind {
        case .setup: return "Not set up yet"
        case .ready: return "Ready"
        case .printing: return "Printing"
        case .attention: return "Needs attention"
        }
    }

    private var tint: Color {
        switch kind {
        case .setup: return .secondary
        case .ready: return .green
        case .printing: return .blue
        case .attention: return .orange
        }
    }
}

struct PrintersView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsInstalledPrinter {
                installedPrinter
            } else {
                discoveryForm
            }
        }
        .frame(maxWidth: 560, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var showsInstalledPrinter: Bool {
        model.selectedQueue != nil && !model.addingPrinter
    }

    private var installedPrinter: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(headline)
                .font(.largeTitle.weight(.semibold))
            Text(model.selectedModel.menuTitle)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(SetupLogic.connectionPhrase(for: model.selectedQueueSummary?.uri ?? ""))
                .foregroundStyle(.secondary)
            Button("Print Test Label") { Task { await model.printEdgeTest() } }
                .prominentAction()
                .disabled(model.busy || model.isPrinting)
            Button("Add another printer") { model.beginAddingPrinter() }
                .buttonStyle(.bordered)
                .disabled(model.busy || model.isPrinting)
        }
    }

    private var discoveryForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(headline)
                .font(.largeTitle.weight(.semibold))
            Text(model.selectedModel.menuTitle)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Turn the printer on and keep it close.")
                .foregroundStyle(.secondary)
            Toggle("Show all Bluetooth devices", isOn: $model.showAllBluetooth)
            PrinterCandidateList(devices: listedDevices, others: otherDevices)
            if let searchLine {
                Text(searchLine)
                    .fixedSize(horizontal: false, vertical: true)
                if model.showBluetoothSettings {
                    Button("Open Bluetooth Settings") { model.openBluetoothSettings() }
                }
            }
            HStack(spacing: 12) {
                Button("Add Printer") { Task { await model.addPrinter() } }
                    .prominentAction()
                    .disabled(model.busy || model.selectedDeviceURI == nil || selectedIsInstalled)
                if model.selectedQueue != nil {
                    Button("Keep current printer") { model.keepCurrentPrinter() }
                        .disabled(model.busy)
                }
            }
            Button("Search again") { model.restartSearch() }
                .disabled(model.busy)
            TextField("Name", text: Binding(
                get: { model.queueName },
                set: { newValue in
                    guard newValue != model.queueName else { return }
                    if newValue.isEmpty && !model.nameTouched {
                        return
                    }
                    model.queueName = newValue
                    model.nameTouched = true
                }
            ), prompt: Text("Filled in when a printer is found"))
            .frame(maxWidth: 320)
            Picker("Model", selection: $model.modelID) {
                ForEach(PrinterModel.catalog) { item in
                    Text(item.menuTitle).tag(item.id)
                }
            }
            .frame(maxWidth: 320)
            if formStatus != nil {
                Text(formStatus ?? "")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var formStatus: String? {
        let text = model.status.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || model.isPrinting || text == SetupLogic.testPrintDone || text == SetupLogic.testPrintProgress {
            return nil
        }
        return text
    }

    private var headline: String {
        if showsInstalledPrinter, let queue = model.selectedQueue, !queue.isEmpty {
            return queue.replacingOccurrences(of: "_", with: " ")
        }
        if let device = selectedDevice {
            return device.name
        }
        return "Add your printer"
    }

    private var searchLine: String? {
        if !model.scanMessage.isEmpty {
            return model.scanMessage
        }
        return nil
    }

    private var selectedDevice: DiscoveredDevice? {
        model.devices.first { $0.uri == model.selectedDeviceURI }
    }

    private var listedDevices: [DiscoveredDevice] {
        model.devices.filter(\.matchesRongta)
    }

    private var otherDevices: [DiscoveredDevice] {
        guard model.showAllBluetooth else { return [] }
        return model.devices.filter { !$0.matchesRongta }
    }

    private var selectedIsInstalled: Bool {
        guard let device = selectedDevice else { return false }
        return SetupLogic.isAlreadyAdded(device, queues: model.queues)
    }
}

struct PrinterCandidateList: View {
    @EnvironmentObject private var model: AppModel
    var devices: [DiscoveredDevice]
    var others: [DiscoveredDevice]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if model.scanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Searching…")
                            .foregroundStyle(.secondary)
                    }
                }
                if devices.isEmpty && others.isEmpty && !model.scanning {
                    Text("No printer found yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    PrinterCandidateRow(device: device)
                }
                if !others.isEmpty {
                    Divider()
                    Text("May not be a Rongta printer")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(others) { device in
                        PrinterCandidateRow(device: device)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible, axes: .vertical)
        .frame(height: 420)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
        )
    }
}

struct PrinterCandidateRow: View {
    @EnvironmentObject private var model: AppModel
    var device: DiscoveredDevice

    var body: some View {
        Button {
            model.chooseDevice(device, userPick: true)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.body.weight(.semibold))
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if already {
                        Text("Already added")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                if device.rssi != 0 {
                    SignalBars(bars: SetupLogic.signalBars(rssi: device.rssi))
                }
                Text("Bluetooth")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
    }

    private var selected: Bool { model.selectedDeviceURI == device.uri }

    private var already: Bool {
        SetupLogic.isAlreadyAdded(device, queues: model.queues)
    }

    private var detail: String {
        if let id = SetupLogic.modelID(matchingBLEName: device.name),
           let model = PrinterModel.find(id) {
            return model.menuTitle
        }
        if device.matchesRongta {
            return "Model not detected"
        }
        return "Choose a model below"
    }
}

struct SignalBars: View {
    var bars: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index <= bars ? Color.primary : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: CGFloat(3 + index * 3))
            }
        }
        .frame(height: 16, alignment: .bottom)
        .accessibilityLabel("Signal \(bars) of 4")
    }
}

struct PaperView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.selectedQueue == nil {
            Text("Add a printer first.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Paper & Settings")
                    .font(.title2.weight(.semibold))
                Picker("Printer", selection: Binding(
                    get: { model.selectedQueue ?? "" },
                    set: { model.selectedQueue = $0 }
                )) {
                    ForEach(model.queues) { queue in
                        Text(queue.name).tag(queue.name)
                    }
                }
                .onChange(of: model.selectedQueue) { _ in
                    Task { await model.loadOptions() }
                }
                Toggle("Custom size", isOn: $model.options.usesCustom)
                if model.options.usesCustom {
                    TextField("Width (inches)", value: $model.options.customWidthInches, format: .number)
                    TextField("Height (inches)", value: $model.options.customHeightInches, format: .number)
                } else {
                    Picker("Label size", selection: $model.options.pageSize) {
                        ForEach(LabelSize.presets) { size in
                            Text(size.title).tag(size.id)
                        }
                    }
                }
                Picker("Paper", selection: $model.options.mediaType) {
                    Text("Gap").tag("Gap")
                    Text("Continuous roll").tag("Continuous")
                    Text("Black mark").tag("BlackMark")
                }
                Stepper("Gap \(model.options.gapMm) mm", value: $model.options.gapMm, in: 0...10)
                Stepper("Darkness \(model.options.darkness)", value: $model.options.darkness, in: 0...15)
                Stepper("Speed \(model.options.speed)", value: $model.options.speed, in: 2...6)
                Picker("Picture", selection: $model.options.dither) {
                    Text("Sharp").tag("Threshold")
                    Text("Photo").tag("FloydSteinberg")
                    Text("Fine pattern").tag("Bayer")
                    Text("Soft pattern").tag("Clustered")
                }
                Button("Save settings") { Task { await model.savePaper() } }
                    .prominentAction()
                    .disabled(model.busy)
            }
            .frame(maxWidth: 460, alignment: .leading)
        }
    }
}

struct CalibrateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.selectedQueue == nil {
            Text("Add a printer first, then print a test label from here.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Calibrate")
                    .font(.title2.weight(.semibold))
                Text("Print a test label. If a line is cut off, move that side out. If you see a white gap, move that side in. Each step is half a millimetre.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Print Test Label") { Task { await model.printEdgeTest() } }
                    .prominentAction()
                    .disabled(model.busy)
                insetStepper("Left", value: $model.deltaLeft)
                insetStepper("Right", value: $model.deltaRight)
                insetStepper("Top", value: $model.deltaTop)
                insetStepper("Bottom", value: $model.deltaBottom)
                HStack(spacing: 12) {
                    Button("Save") { Task { await model.saveCalibration() } }
                        .prominentAction(large: false)
                        .disabled(model.busy)
                    Button("Print again to check") { Task { await model.printEdgeTest() } }
                        .disabled(model.busy)
                    Button("Reset") { Task { await model.resetCalibration() } }
                        .disabled(model.busy)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
    }

    private func insetStepper(_ title: String, value: Binding<Double>) -> some View {
        Stepper(value: value, in: -20...20, step: 0.5) {
            LabeledContent(title) {
                Text(String(format: "%+.1f mm", value.wrappedValue))
                    .monospacedDigit()
            }
        }
    }
}

struct HelpView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Help")
                .font(.title2.weight(.semibold))
            Text("Rongta Label Setup")
                .font(.title3)
            Text("by blankspeaker (x.com/blankspeaker) and Grok Bot (x.ai/bot)")
            Text("Project page: \(SetupLogic.projectPage.absoluteString)")
                .textSelection(.enabled)
            Button("Project page on GitHub") {
                openURL(SetupLogic.projectPage)
            }
            .buttonStyle(.bordered)
            Text("Not affiliated with or endorsed by Rongta. Rongta, ZPL (Zebra), TSPL (TSC) and Bluetooth are trademarks of their respective owners. Free software, GPL-3.0-or-later.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Add your printer, choose the label size, and print a test label. If the print sits too far in or gets cut off, use Calibrate and measure the gap in millimetres.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Uninstall Rongta Label Setup") {
                model.confirmUninstall = true
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(model.busy)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}
