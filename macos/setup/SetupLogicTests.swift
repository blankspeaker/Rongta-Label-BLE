// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

var fails = 0

func check(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("FAIL \(message)\n", stderr)
        fails += 1
    }
}

func testMillimetres() {
    check(SetupLogic.insetDots(forMillimetres: 0) == 0, "0 mm")
    check(SetupLogic.insetDots(forMillimetres: 0.5) == 4, "0.5 mm")
    check(SetupLogic.insetDots(forMillimetres: 1) == 8, "1 mm")
    check(SetupLogic.insetDots(forMillimetres: 1.5) == 12, "1.5 mm")
    check(SetupLogic.insetDots(forMillimetres: -2) == -16, "-2 mm")
    check(SetupLogic.adjustedInset(current: 8, millimetres: 1) == 16, "add 1 mm")
    check(SetupLogic.adjustedInset(current: 8, millimetres: -0.5) == 4, "remove 0.5 mm")
    check(SetupLogic.adjustedInset(current: 2, millimetres: -1) == 0, "clamp low")
    check(SetupLogic.adjustedInset(current: 798, millimetres: 0.5) == 800, "clamp high")
    let adjusted = SetupLogic.applyAdjustments(
        SetupLogic.defaultOptions(language: .zpl),
        leftMM: 1,
        rightMM: -0.5,
        topMM: 0,
        bottomMM: 0.5
    )
    check(adjusted.insetLeft == 16 && adjusted.insetRight == 4, "zpl side adjust")
    check(adjusted.insetTop == 32 && adjusted.insetBottom == 4, "zpl vertical adjust")
    check(adjusted.labelHomeX == 20 && adjusted.labelTop == -20, "offsets unchanged")
}

func testLpoptions() {
    let sample = """
    PageSize/Media Size: 4x4in *4x6in 4x3in
    MediaType/Media: *Gap Continuous BlackMark
    Darkness/Darkness: 0 1 *7 15
    PrintSpeed/Print Speed: 2 3 4 *5 6
    rtDither/Dither: *Threshold FloydSteinberg Bayer Clustered
    rtGapMm/Gap or Mark: 0 *2 3 4
    rtInsetLeft/Inset Left: 0 4 *8 12
    rtInsetRight/Inset Right: *8 0
    rtInsetTop/Inset Top: 0 *32 40
    rtInsetBottom/Inset Bottom: *0 8
    rtLabelHomeX/Horizontal Offset: -40 *20 40
    rtLabelTop/Vertical Offset: -120 *-20 0 20
    """
    let parsed = SetupLogic.parseLpoptionsList(sample)
    check(parsed["PageSize"] == "4x6in", "page size star")
    check(parsed["MediaType"] == "Gap", "media star")
    check(parsed["Darkness"] == "7", "darkness star")
    check(parsed["rtLabelTop"] == "-20", "negative star")
    check(parsed["rtInsetBottom"] == "0", "zero star")
    let options = SetupLogic.queueOptions(from: parsed, language: .zpl)
    check(options.pageSize == "4x6in" && !options.usesCustom, "loaded page")
    check(options.insetLeft == 8 && options.insetTop == 32 && options.insetBottom == 0, "loaded inset")
    check(options.labelHomeX == 20 && options.labelTop == -20, "loaded offsets")
    check(options.darkness == 7 && options.speed == 5 && options.gapMm == 2, "loaded knobs")
    let custom = SetupLogic.queueOptions(from: ["PageSize": "Custom.3.5x2in"], language: .tspl)
    check(custom.usesCustom && custom.customWidthInches == 3.5 && custom.customHeightInches == 2, "custom parse")
    check(custom.insetLeft == 0 && custom.insetTop == 0, "tspl default inset when unset")
}

func testCommands() {
    let model = PrinterModel.find("RP425")!
    let ppd = SetupLogic.ppdPath(for: model, directory: "/Library/Printers/PPDs/Contents/Resources")
    let add = SetupLogic.lpadminAddArguments(
        queue: "RP425",
        uri: "rongta-bt://RP425",
        ppdPath: ppd,
        description: "Rongta RP425",
        pageSize: "4x6in"
    )
    check(add == [
        "/usr/sbin/lpadmin", "-p", "RP425", "-E", "-v", "rongta-bt://RP425",
        "-P", "/Library/Printers/PPDs/Contents/Resources/Rongta_RP425_ZPL_203dpi.ppd",
        "-D", "Rongta RP425", "-o", "PageSize=4x6in",
    ], "add arguments")
    let shell = SetupLogic.addPrinterShellCommand(
        queue: "RP425",
        uri: "rongta-bt://RP425",
        ppdPath: ppd,
        description: "Rongta RP425",
        pageSize: "4x6in"
    )
    check(shell.contains("&&"), "default follows add")
    check(shell.contains("'-d' 'RP425'"), "default printer")
    check(shell.contains("/usr/sbin/cupsenable 'RP425'"), "enables the queue")
    check(shell.contains("/usr/sbin/cupsaccept 'RP425'"), "accepts jobs")
    check(shell.contains("PageSize=4x6in"), "four by six")
    check(SetupLogic.userDefaultArguments(queue: "RP425") == ["/usr/bin/lpoptions", "-d", "RP425"], "user default")
    check(SetupLogic.enableQueueShellCommand(queue: "Labels") == "/usr/sbin/cupsenable 'Labels' && /usr/sbin/cupsaccept 'Labels'", "enable command")
    check(SetupLogic.lpadminShellCommand([DriverPaths.uninstall]).contains("uninstall.sh"), "uninstall command")
    var paper = SetupLogic.defaultOptions(language: .zpl)
    paper.usesCustom = true
    paper.customWidthInches = 4
    paper.customHeightInches = 6.5
    let set = SetupLogic.lpadminSetArguments(queue: "Labels", pairs: SetupLogic.paperOptionPairs(paper))
    check(set == [
        "/usr/sbin/lpadmin", "-p", "Labels",
        "-o", "PageSize=Custom.4x6.5in",
        "-o", "MediaType=Gap",
        "-o", "rtGapMm=2",
        "-o", "Darkness=7",
        "-o", "PrintSpeed=5",
        "-o", "rtDither=Threshold",
    ], "paper arguments")
    let cal = SetupLogic.lpadminSetArguments(
        queue: "Labels",
        pairs: SetupLogic.calibrationPairs(SetupLogic.defaultOptions(language: .tspl))
    )
    check(cal.contains("-o") && cal.contains("rtInsetLeft=0") && cal.contains("rtInsetTop=0"), "tspl reset")
    check(cal.contains("rtLabelHomeX=20") && cal.contains("rtLabelTop=-20"), "offset reset")
    let zplCal = SetupLogic.calibrationPairs(SetupLogic.defaultOptions(language: .zpl))
    check(zplCal.map(\.1) == ["8", "8", "32", "0", "20", "-20"], "zpl calibration values")
    check(SetupLogic.lpEdgeTestArguments(queue: "Labels", pageSize: "2x1in", pdfPath: "/tmp/2x1in.pdf") == [
        "/usr/bin/lp", "-d", "Labels", "-o", "PageSize=2x1in", "/tmp/2x1in.pdf",
    ], "edge lp")
    check(SetupLogic.edgeTestFilename(pageSize: "4x6in") == "4x6in.pdf", "named edge file")
    check(SetupLogic.edgeTestFilename(pageSize: "2x1in") == "2x1in.pdf", "small edge file")
    check(SetupLogic.edgeTestFilename(pageSize: "Custom.3.5x2in") == nil, "custom is generated")
    check(SetupLogic.edgeTestFilename(pageSize: "../etc") == nil, "edge path escape")
    check(SetupLogic.edgeTestFilename(pageSize: "a/b") == nil, "edge slash")
    let script = SetupLogic.administratorAppleScript(
        shellCommand: SetupLogic.lpadminShellCommand(["/usr/sbin/lpadmin", "-p", "O'Brien", "-D", "say \"hi\""])
    )
    check(SetupLogic.shellSingleQuote("O'Brien") == "'O'\\''Brien'", "shell quote")
    check(script.contains("with administrator privileges"), "admin prompt")
    check(!script.lowercased().contains("password"), "no password")
    check(script.contains("/usr/sbin/lpadmin"), "admin runs lpadmin")
    check(script.contains("Brien"), "name survived quoting")
    check(!script.contains("say \"hi\""), "inner quotes escaped")
}

func testDiscovery() {
    let ble = SetupLogic.parseBleScan("DEV\trongta-bt://RP425\tRP425\nnoise\nDEV\trongta-bt://ABC\t\n")
    check(ble.count == 2 && ble[0].name == "RP425" && ble[0].transport == .bluetooth, "ble row")
    check(ble[1].name == "rongta-bt://ABC", "ble fallback name")
    let rich = SetupLogic.parseBleScan("DEV\trongta-bt://OLD\tOLD\t-40\trongta\tOLDID\nEND\nDEV\trongta-bt://RP420-WXYZ\tRP420-WXYZ\t-72\trongta\t11111111-2222-3333-4444-555555555555\nDEV\trongta-bt://AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\tDesk lamp\t-68\tother\tAAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\n")
    check(rich.count == 2 && rich[0].name == "RP420-WXYZ" && rich[0].rssi == -72, "end snapshot drops stale rows")
    check(rich[1].matchesRongta == false && rich[1].peripheralID.hasPrefix("AAAAAAAA"), "other device keeps its id")
    check(SetupLogic.signalBars(rssi: -55) == 4 && SetupLogic.signalBars(rssi: -88) == 1, "signal bars")
    check(SetupLogic.signalBars(rssi: 0) == 0, "unknown signal")
    let added = DiscoveredDevice(uri: "rongta-bt://RP425-ABCD", name: "RP425-ABCD", transport: .bluetooth)
    let queues = [QueueSummary(name: "Kitchen_labels", uri: "rongta-bt://RP425-ABCD", language: .zpl)]
    check(SetupLogic.isAlreadyAdded(added, queues: queues), "installed printer is marked")
    check(SetupLogic.friendlyPrintError("ERR no FF02 characteristic\n") == SetupLogic.incompatibleConnection, "friendly characteristic error")
    check(SetupLogic.sanitizeQueueName("RP 425") == "RP_425", "space")
    check(SetupLogic.sanitizeQueueName("O'Brien") == "OBrien", "apostrophe")
    check(SetupLogic.uniqueQueueName("RP425", existing: ["RP425", "RP425_2"]) == "RP425_3", "unique")
    check(SetupLogic.initialSection(queueCount: 0) == .printers, "no queue opens add")
    check(SetupLogic.initialSection(queueCount: 2) == .printers, "install opens add")
    check(SetupLogic.modelID(matchingBLEName: "RP425-ABCD") == "RP425", "rp425 name")
    check(SetupLogic.modelID(matchingBLEName: "rp421a-1") == "RP421A", "rp421a name")
    check(SetupLogic.modelID(matchingBLEName: "RP420") == "RP420", "rp420 name")
    check(SetupLogic.modelID(matchingBLEName: "Label-ZPL") == nil, "generic name is not guessed")
    let printer = DiscoveredDevice(
        uri: "rongta-bt://RP420-WXYZ",
        name: "RP420-WXYZ",
        transport: .bluetooth,
        rssi: -70,
        matchesRongta: true,
        peripheralID: "11111111-2222-3333-4444-555555555555"
    )
    let lamp = DiscoveredDevice(
        uri: "rongta-bt://BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
        name: "Desk lamp",
        transport: .bluetooth,
        rssi: -68,
        matchesRongta: false,
        peripheralID: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    )
    let held = SetupLogic.mergeDiscovered([printer, lamp], with: [])
    check(held.map(\.name) == ["RP420-WXYZ", "Desk lamp"], "empty update keeps every device")
    var weaker = printer
    weaker.rssi = -85
    let stayed = SetupLogic.mergeDiscovered([printer, lamp], with: [weaker])
    check(stayed.count == 2 && stayed[0].rssi == -85 && stayed[1].name == "Desk lamp", "missing device stays, signal updates")
    check(stayed.map(\.uri) == [printer.uri, lamp.uri], "a signal change does not reorder")
    let addedPrinter = DiscoveredDevice(
        uri: "rongta-bt://RP425-ABCD",
        name: "RP425-ABCD",
        transport: .bluetooth,
        rssi: -50,
        matchesRongta: true,
        peripheralID: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    )
    let joined = SetupLogic.mergeDiscovered([printer, lamp], with: [addedPrinter])
    check(joined.map(\.name) == ["RP420-WXYZ", "RP425-ABCD", "Desk lamp"], "new printer joins the printer section")
    let later = DiscoveredDevice(
        uri: "rongta-bt://RP422-ZZZZ",
        name: "RP422-ZZZZ",
        transport: .bluetooth,
        rssi: -40,
        matchesRongta: true,
        peripheralID: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
    )
    let earlierName = DiscoveredDevice(
        uri: "rongta-bt://RP410-AAAA",
        name: "RP410-AAAA",
        transport: .bluetooth,
        rssi: -90,
        matchesRongta: true,
        peripheralID: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
    )
    let namedAtInsert = SetupLogic.mergeDiscovered([printer, lamp], with: [later, earlierName])
    check(
        namedAtInsert.map(\.name) == ["RP420-WXYZ", "RP410-AAAA", "RP422-ZZZZ", "Desk lamp"],
        "new printers are name-sorted once, then stay put"
    )
    let uuidRow = DiscoveredDevice(
        uri: "rongta-bt://11111111-2222-3333-4444-555555555555",
        name: "Unknown device 11111111",
        transport: .bluetooth,
        rssi: -80,
        matchesRongta: false,
        peripheralID: "11111111-2222-3333-4444-555555555555"
    )
    let sameRadio = SetupLogic.mergeDiscovered([uuidRow], with: [printer])
    check(
        sameRadio.count == 1 && sameRadio[0].uri == uuidRow.uri && sameRadio[0].name == "RP420-WXYZ" && sameRadio[0].rssi == -70,
        "the same radio updates its row and keeps the original uri"
    )
    let only = DiscoveredDevice(uri: "rongta-bt://RP425", name: "RP425-ABCD", transport: .bluetooth)
    check(SetupLogic.soleDevice([only, only])?.uri == only.uri, "one printer after dedupe")
    check(SetupLogic.soleDevice([]) == nil, "no printer")
    check(SetupLogic.soleDevice([
        only,
        DiscoveredDevice(uri: "rongta-bt://other", name: "RP422-1", transport: .bluetooth),
    ]) == nil, "two printers")
    check(SetupLogic.queueUsesDriver(ppdText: "*cupsFilter: \"application/vnd.cups-raster 100 rastertozpl-rt\"\n", ppdPath: nil, deviceURI: "rongta-bt://x") , "zpl ppd")
    check(SetupLogic.language(ofPPD: "rastertotspl-rt") == .tspl, "tspl language")
    check(!SetupLogic.queueUsesDriver(ppdText: "other", ppdPath: "/tmp/other.ppd", deviceURI: "ipp://plain"), "unrelated queue")
    check(SetupLogic.queueUsesDriver(ppdText: nil, ppdPath: nil, deviceURI: "rongta-bt://auto"), "backend uri")
    let devices = SetupLogic.parseLpstatDevices("device for Labels: rongta-bt://RP425\ndevice for Other: ipp://printer\n")
    check(devices["Labels"] == "rongta-bt://RP425" && devices["Other"] == "ipp://printer", "lpstat devices")
    check(SetupLogic.customPageSize(widthInches: 4, heightInches: 6) == "Custom.4x6in", "custom whole")
    check(SetupLogic.customSizeError(widthInches: 0.2, heightInches: 6) != nil, "custom width")
    check(SetupLogic.customSizeError(widthInches: 4, heightInches: 6) == nil, "custom ok")
}

func testEmptyPrinterList() {
    let message = "lpstat: No destinations added.\n"
    check(SetupLogic.parseLpstatDevices(message).isEmpty, "no device lines")
    check(SetupLogic.isBenignCupsFailure(status: 1, stdout: "", stderr: message), "empty lpstat")
    check(SetupLogic.isBenignCupsFailure(status: 1, stdout: message, stderr: ""), "empty lpstat on stdout")
    check(!SetupLogic.isBenignCupsFailure(status: 0, stdout: "", stderr: message), "success is not a failure")
    check(!SetupLogic.isBenignCupsFailure(status: 1, stdout: "", stderr: "lpstat: server error"), "real lpstat error")
    check(SetupLogic.isBenignCupsFailure(
        status: 1, stdout: "", stderr: "lpoptions: Unknown printer or class.\n"
    ), "missing queue")
    let listed = SetupLogic.parseLpstatDevices("device for Labels: rongta-bt://RP425\n")
    check(listed["Labels"] == "rongta-bt://RP425", "real queue still parses")
}

func testBluetoothGate() {
    let denied = BluetoothGate.step(
        authorization: .denied, radio: .unauthorized, stateIsLive: false, unauthorizedSamples: 1
    )
    check(denied == .wait, "pre-delegate denial is not a decision")
    let earlyGrant = BluetoothGate.step(
        authorization: .allowedAlways, radio: .poweredOn, stateIsLive: false, unauthorizedSamples: 0
    )
    check(earlyGrant == .wait, "class property is not a grant before the delegate")
    let prompt = BluetoothGate.step(
        authorization: .notDetermined, radio: .unauthorized, stateIsLive: true, unauthorizedSamples: 5
    )
    check(prompt == .wait, "notDetermined keeps waiting")
    let restricted = BluetoothGate.step(
        authorization: .restricted, radio: .poweredOn, stateIsLive: true, unauthorizedSamples: 0
    )
    check(restricted == .fail(BluetoothGate.permissionDenied), "restricted fails live")
    let liveDenied = BluetoothGate.step(
        authorization: .denied, radio: .unauthorized, stateIsLive: true, unauthorizedSamples: 1
    )
    check(liveDenied == .fail(BluetoothGate.permissionDenied), "live denial is reported")
    let blip = BluetoothGate.step(
        authorization: .allowedAlways, radio: .unauthorized, stateIsLive: true,
        unauthorizedSamples: BluetoothGate.unauthorizedGrace - 1
    )
    check(blip == .wait, "unauthorized is not cached before the grace period")
    let stuck = BluetoothGate.step(
        authorization: .allowedAlways, radio: .unauthorized, stateIsLive: true,
        unauthorizedSamples: BluetoothGate.unauthorizedGrace
    )
    check(stuck == .fail(BluetoothGate.permissionDenied), "repeated unauthorized is a real error")
    let ready = BluetoothGate.step(
        authorization: .allowedAlways, radio: .poweredOn, stateIsLive: true, unauthorizedSamples: 0
    )
    check(ready == .proceed, "powered on proceeds")
    let off = BluetoothGate.step(
        authorization: .allowedAlways, radio: .poweredOff, stateIsLive: true, unauthorizedSamples: 0
    )
    check(off == .fail("ERR Bluetooth is off\n"), "radio off")
}

func testPrintWatch() {
    check(SetupLogic.printersNeedAttention("printer Labels disabled since today -\n"), "disabled printer")
    check(!SetupLogic.printersNeedAttention("printer Labels is idle.  enabled since today\n"), "enabled printer")
    check(SetupLogic.testPrintProgress.contains("up to 30 seconds"), "print heads-up")
    check(SetupLogic.testPrintWaitNote.contains("up to 30 seconds"), "print confirm")
    check(SetupLogic.testPrintDone == "Done! Check your printer.", "print done")
    check(SetupLogic.parseJobID("request id is Labels-23 (1 file(s))\n") == "Labels-23", "job id")
    check(SetupLogic.parseJobID("noise\n") == nil, "missing job id")
    let disabled = """
    printer Labels disabled since Thu Oct  8 11:00:00 2026 -
    \tRongta Bluetooth helper failed (no reply; is the logged-in helper running?)
    """
    let stopped = SetupLogic.interpretPrintState(
        printerText: disabled,
        pendingJobs: "Labels-23 user 100 Thu Oct  8 11:00:00 2026\n",
        completedJobs: "",
        jobID: "Labels-23"
    )
    check(stopped == .failed("Rongta Bluetooth helper failed (no reply; is the logged-in helper running?)"), "disabled message")
    let idle = "printer Labels is idle.  enabled since Thu Oct  8 11:00:00 2026\n"
    let waiting = SetupLogic.interpretPrintState(
        printerText: idle, pendingJobs: "", completedJobs: "", jobID: "Labels-23"
    )
    check(waiting == .pending, "not listed yet")
    let queued = SetupLogic.interpretPrintState(
        printerText: idle,
        pendingJobs: "Labels-23 user 100 Thu Oct  8 11:00:00 2026\n",
        completedJobs: "",
        jobID: "Labels-23"
    )
    check(queued == .pending, "still printing")
    let done = SetupLogic.interpretPrintState(
        printerText: idle,
        pendingJobs: "",
        completedJobs: "Labels-23 user 100 Thu Oct  8 11:00:00 2026\n",
        jobID: "Labels-23"
    )
    check(done == .succeeded, "completed job")
    let aborted = SetupLogic.interpretPrintState(
        printerText: idle,
        pendingJobs: "Labels-23 user 100 Thu Oct  8 11:00:00 2026\n\tStatus: aborted\n",
        completedJobs: "",
        jobID: "Labels-23"
    )
    check(aborted == .failed("Status: aborted"), "aborted job")
    let other = SetupLogic.interpretPrintState(
        printerText: idle,
        pendingJobs: "Labels-99 user 100 Thu Oct  8 11:00:00 2026\n",
        completedJobs: "",
        jobID: "Labels-23"
    )
    check(other == .pending, "another job is not this one")
}

func testEdgePDF() {
    let small = EdgeTestPDF.render(width: 144, height: 72, title: "2 x 1 EDGE TEST")
    let smallText = String(data: small, encoding: .ascii) ?? ""
    check(smallText.contains("/MediaBox [0 0 144.00 72.00]"), "2x1 box")
    check(smallText.contains("(2 x 1 EDGE TEST)"), "2x1 title")
    check(!smallText.contains("solid line = label edge"), "2x1 drops the caption")
    check(!smallText.contains("(LEFT)"), "2x1 drops LEFT")
    let tall = EdgeTestPDF.render(width: 288, height: 432, title: "4 x 6 EDGE TEST")
    let tallText = String(data: tall, encoding: .ascii) ?? ""
    check(tallText.contains("solid line = label edge"), "4x6 caption")
    check(tallText.contains("(4 x 6 EDGE TEST)"), "4x6 title")
    let custom = EdgeTestPDF.render(pageSize: "Custom.3.5x2in")
    let customText = String(data: custom ?? Data(), encoding: .ascii) ?? ""
    check(customText.contains("/MediaBox [0 0 252.00 144.00]"), "custom box")
    check(customText.contains("(3.5 x 2 EDGE TEST)"), "custom title")
    check(EdgeTestPDF.render(pageSize: "2x1in") == nil, "named size is a file")
    check(EdgeTestPDF.render(pageSize: "Custom.nope") == nil, "bad custom")
}

func testHelperProtocol() {
    let reply = SetupLogic.parseHelperReply("DEV\trongta-bt://RP425-ABCD\tRP425-ABCD\nOK\n")
    check(reply.ok && reply.devices.count == 1 && reply.devices[0].name == "RP425-ABCD", "helper scan reply")
    check(!reply.needsPermission, "granted scan is not a permission error")
    let denied = SetupLogic.parseHelperReply("ERR Bluetooth permission denied\n")
    check(!denied.ok && denied.needsPermission && denied.devices.isEmpty, "needs permission")
    let explained = SetupLogic.explainBluetoothScan(status: 1, stdout: "", stderr: denied.message)
    check(explained.openBluetoothSettings, "permission reply opens settings")
    check(!explained.message.contains("Exit code"), "permission reply stays friendly")
    check(SetupLogic.kickstartArguments(uid: 501) == [
        "/bin/launchctl", "kickstart", "gui/501/com.blankspeaker.rongta-label",
    ], "kickstart")
    check(SetupLogic.helperScanLine == "SCAN" && SetupLogic.helperScanAllLine == "SCAN ALL", "protocol lines")
    check(SetupLogic.helperWatchLine == "WATCH ALL", "watch line")
    let visible = SetupLogic.FittedFrame(x: 0, y: 0, width: 1600, height: 1200)
    let small = SetupLogic.fittedWindowFrame(
        current: SetupLogic.FittedFrame(x: 40, y: 30, width: 700, height: 500),
        minimumWidth: 1040,
        minimumHeight: 908,
        visible: visible
    )
    check(small.width == 1040 && small.height == 908, "a small saved frame grows to the page")
    check(small.x == 40 && small.y == 30, "a frame that still fits keeps its place")
    let cramped = SetupLogic.fittedWindowFrame(
        current: SetupLogic.FittedFrame(x: 80, y: 60, width: 640, height: 480),
        minimumWidth: 1040,
        minimumHeight: 908,
        visible: SetupLogic.FittedFrame(x: 0, y: 0, width: 1280, height: 800)
    )
    check(cramped.width == 1040 && cramped.height == 800, "growth stops at the visible screen")
    check(
        cramped.x >= 0 && cramped.x + cramped.width <= 1280
            && cramped.y >= 0 && cramped.y + cramped.height <= 800,
        "the window stays on screen"
    )
    check(SetupLogic.helperStatusLine == "STATUS", "status line")
    check(SetupLogic.helperIsUnreachable("Could not reach the Bluetooth helper."), "unreachable")
    check(!SetupLogic.helperIsUnreachable(denied.message), "permission is not unreachable")
}

func testBluetoothExitCodes() {
    let crashed = SetupLogic.explainBluetoothScan(status: 6, stdout: "", stderr: "")
    check(crashed.openBluetoothSettings, "permission opens settings")
    check(crashed.message.contains("Privacy & Security"), "friendly privacy text")
    check(crashed.message.contains("Rongta Label Setup"), "names the app")
    check(crashed.message.contains("rongta-ble"), "names the helper that scans")
    check(!crashed.message.contains("Exit code"), "raw code stays out of the message")
    check(crashed.detail.contains("Exit code 6."), "detail has the code")
    let denied = SetupLogic.explainBluetoothScan(
        status: 1, stdout: "", stderr: "ERR Bluetooth permission denied\n"
    )
    check(denied.openBluetoothSettings && denied.message == crashed.message, "denied text")
    let off = SetupLogic.explainBluetoothScan(status: 1, stdout: "", stderr: "ERR Bluetooth is off\n")
    check(!off.openBluetoothSettings, "off is not the privacy pane")
    check(off.message.contains("Turn Bluetooth on"), "off text")
    check(off.detail.contains("Exit code 1."), "off detail")
    let other = SetupLogic.explainBluetoothScan(status: 2, stdout: "", stderr: "boom")
    check(other.message.isEmpty, "generic scan does not linger as still looking")
    check(other.detail.contains("boom") && other.detail.contains("Exit code 2."), "generic detail")
    check(SetupLogic.connectionPhrase(for: "rongta-bt://RP425-ABCD") == "Connected over Bluetooth", "bluetooth connection")
    check(SetupLogic.projectPage.absoluteString == "https://github.com/blankspeaker/Rongta-Label-BLE", "project page")
    let found = [DiscoveredDevice(uri: "rongta-bt://RP425-ABCD", name: "RP425-ABCD", transport: .bluetooth)]
    check(SetupLogic.preferredDevice(found, matchingURI: nil)?.name == "RP425-ABCD", "one printer is chosen")
}

@main
enum SetupLogicTestMain {
    static func main() {
        testMillimetres()
        testLpoptions()
        testCommands()
        testDiscovery()
        testEmptyPrinterList()
        testBluetoothExitCodes()
        testBluetoothGate()
        testHelperProtocol()
        testPrintWatch()
        testEdgePDF()
        if fails != 0 {
            fputs("\(fails) setup logic failure(s)\n", stderr)
            exit(1)
        }
        print("setup logic tests ok")
    }
}
