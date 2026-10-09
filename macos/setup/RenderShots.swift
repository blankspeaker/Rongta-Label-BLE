// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 blankspeaker (x.com/blankspeaker) and Grok Bot (x.ai/bot)
// Headless screenshots of Rongta Label Setup. The window stays transparent and
// off the visible desktop. Preview names are generic. Not part of the app target.
import AppKit
import SwiftUI

@MainActor
@main
enum RenderShots {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let out = URL(
            fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try render(to: out)
            print("wrote \(out.path)")
            exit(0)
        } catch {
            fputs("render failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func render(to out: URL) throws {
        let pages: [(String, AppModel)] = [
            ("printer-set-up", ready()),
            ("printer-not-set-up", notSetUp()),
            ("add-printer", picker()),
            ("paper", paper()),
            ("calibrate", calibrate()),
            ("help", help()),
        ]
        for (name, model) in pages {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let suffix = scheme == .dark ? "-dark" : ""
                try shot("\(name)\(suffix)", model, scheme: scheme, to: out)
            }
        }
    }

    /// Natural size of the page with no window minimum applied. This is what must fit.
    static func contentFittingSize(_ model: AppModel, scheme: ColorScheme) -> NSSize {
        let view = SetupChrome(scrolls: false)
            .environmentObject(model)
            .environment(\.colorScheme, scheme)
            .environment(\.shotActions, true)
            .frame(width: SetupWindow.contentWidth, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: SetupWindow.contentWidth, height: 4000)
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.appearance = appearance
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0
        window.isExcludedFromWindowsMenu = true
        window.sharingType = .none
        window.appearance = appearance
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -32000, y: -32000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        window.orderOut(nil)
        window.close()
        return fit
    }

    /// Ideal size with no width proposal, so a control that wants to be wider than the window is visible to the check.
    static func naturalSize(_ model: AppModel, scheme: ColorScheme) -> NSSize {
        let view = SetupChrome(scrolls: false)
            .environmentObject(model)
            .environment(\.colorScheme, scheme)
            .environment(\.shotActions, true)
            .fixedSize(horizontal: true, vertical: true)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 2400, height: 2400)
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.appearance = appearance
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0
        window.isExcludedFromWindowsMenu = true
        window.sharingType = .none
        window.appearance = appearance
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -32000, y: -32000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        window.orderOut(nil)
        window.close()
        return fit
    }

    static func shot(_ name: String, _ model: AppModel, scheme: ColorScheme, to out: URL) throws {
        let fit = contentFittingSize(model, scheme: scheme)
        let natural = naturalSize(model, scheme: scheme)
        let windowSize = NSSize(width: SetupWindow.contentWidth, height: SetupWindow.contentHeight)
        if fit.width > windowSize.width + 1 || fit.height > windowSize.height + 1
            || natural.width > windowSize.width + 1 || natural.height > windowSize.height + 1 {
            throw NSError(domain: "RenderShots", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "\(name) clips: fitting \(Int(fit.width))x\(Int(fit.height)) natural \(Int(natural.width))x\(Int(natural.height)) window \(Int(windowSize.width))x\(Int(windowSize.height))"
            ])
        }
        print("\(name) fitting \(Int(fit.width))x\(Int(ceil(fit.height))) natural \(Int(natural.width))x\(Int(ceil(natural.height))) <= \(Int(windowSize.width))x\(Int(windowSize.height))")
        let view = ContentView()
            .environmentObject(model)
            .environment(\.colorScheme, scheme)
            .environment(\.shotActions, true)
            .frame(width: windowSize.width, height: windowSize.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.appearance = appearance

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.alphaValue = 0
        window.isExcludedFromWindowsMenu = true
        window.sharingType = .none
        window.appearance = appearance
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -32000, y: -32000))
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.makeKey()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.orderOut(nil)
            window.close()
            throw NSError(domain: "RenderShots", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No bitmap for \(name)"
            ])
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        window.close()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "RenderShots", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not encode \(name)"
            ])
        }
        try data.write(to: out.appendingPathComponent("\(name).png"))
    }

    static func ready() -> AppModel {
        let model = AppModel()
        let uri = "rongta-bt://RP425-ABCD"
        model.devices = [DiscoveredDevice(uri: uri, name: "RP425-ABCD", transport: .bluetooth)]
        model.selectedDeviceURI = uri
        model.queues = [QueueSummary(name: "Kitchen_labels", uri: uri, language: .zpl)]
        model.selectedQueue = "Kitchen_labels"
        model.queueName = "Kitchen labels"
        model.modelID = "RP425"
        model.section = .printers
        return model
    }

    static func notSetUp() -> AppModel {
        let model = AppModel()
        model.section = .printers
        model.modelID = "RP425"
        model.queues = []
        model.selectedQueue = nil
        model.addingPrinter = false
        model.scanning = false
        model.showAllBluetooth = false
        return model
    }

    static func searching() -> AppModel {
        let model = AppModel()
        model.section = .printers
        model.modelID = "RP425"
        model.scanning = true
        model.scanMessage = ""
        return model
    }

    static func attention() -> AppModel {
        let model = ready()
        model.needsAttention = true
        return model
    }

    static func printing() -> AppModel {
        let model = ready()
        model.isPrinting = true
        model.busy = true
        model.status = SetupLogic.testPrintProgress
        return model
    }

    static func done() -> AppModel {
        let model = ready()
        model.status = SetupLogic.testPrintDone
        return model
    }

    static func paper() -> AppModel {
        let model = ready()
        model.section = .paper
        return model
    }

    static func calibrate() -> AppModel {
        let model = ready()
        model.section = .calibrate
        model.deltaLeft = 0.5
        model.deltaTop = -1.0
        return model
    }

    static func help() -> AppModel {
        let model = ready()
        model.section = .help
        return model
    }

    static func picker() -> AppModel {
        let model = AppModel()
        model.section = .printers
        model.addingPrinter = true
        model.showAllBluetooth = true
        model.modelID = "RP420"
        model.queues = [QueueSummary(name: "Kitchen_labels", uri: "rongta-bt://RP425-ABCD", language: .zpl)]
        model.selectedQueue = "Kitchen_labels"
        let added = DiscoveredDevice(
            uri: "rongta-bt://RP425-ABCD",
            name: "RP425-ABCD",
            transport: .bluetooth,
            rssi: -55,
            matchesRongta: true
        )
        let chosen = DiscoveredDevice(
            uri: "rongta-bt://RP420-WXYZ",
            name: "RP420-WXYZ",
            transport: .bluetooth,
            rssi: -72,
            matchesRongta: true
        )
        let generics: [(String, Int)] = [
            ("Desk lamp", -68),
            ("Headphones", -62),
            ("Keyboard", -74),
            ("Mouse", -71),
            ("Speaker", -80),
            ("Watch", -66),
            ("Thermostat", -84),
            ("Light bulb", -77),
            ("Phone", -63),
            ("Tablet", -69),
            ("Scale", -82),
            ("Tracker", -75),
            ("Unknown device A1B2C3D4", -88),
            ("Unknown device B2C3D4E5", -91),
        ]
        var rows = [added, chosen]
        for (index, item) in generics.enumerated() {
            let hex = String(format: "%012X", index + 1)
            let id = "AAAAAAAA-BBBB-CCCC-DDDD-\(hex)"
            rows.append(DiscoveredDevice(
                uri: "rongta-bt://\(id)",
                name: item.0,
                transport: .bluetooth,
                rssi: item.1,
                matchesRongta: false,
                peripheralID: id
            ))
        }
        model.devices = rows
        model.selectedDeviceURI = chosen.uri
        model.queueName = "RP420-WXYZ"
        model.scanning = true
        return model
    }

    static func bluetooth() -> AppModel {
        let model = AppModel()
        model.section = .printers
        model.modelID = "RP425"
        model.scanning = false
        model.showBluetoothSettings = true
        model.scanMessage = "Allow Bluetooth for Rongta Label Setup in System Settings → Privacy & Security → Bluetooth. If the list says rongta-ble, allow that. It is the program that scans and prints."
        return model
    }
}
