// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 blankspeaker (x.com/blankspeaker) and Grok Bot (x.ai/bot)
// Draws the Rongta Label Setup icon: a white shipping label on a rounded square.
// No third-party artwork. Generic bars only, no words and no personal data.
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    let r = CGFloat((hex >> 16) & 0xff) / 255
    let g = CGFloat((hex >> 8) & 0xff) / 255
    let b = CGFloat(hex & 0xff) / 255
    return NSColor(calibratedRed: r, green: g, blue: b, alpha: alpha)
}

func drawLabelIcon() {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    ctx.clear(bounds)

    let squircle = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 8), xRadius: 228, yRadius: 228)
    ctx.saveGState()
    squircle.addClip()
    let gradient = NSGradient(colors: [color(0x2F6F8F), color(0x1C4C6E), color(0x16324C)])!
    gradient.draw(in: bounds, angle: -70)

    // Soft highlight so the tile does not look flat.
    let glow = NSGradient(colors: [color(0xFFFFFF, alpha: 0.22), color(0xFFFFFF, alpha: 0)])!
    glow.draw(in: CGRect(x: 0, y: 520, width: canvas, height: 520), angle: -90)
    ctx.restoreGState()

    // Printer accent, drawn first so the label covers most of it.
    let printer = CGRect(x: 700, y: 108, width: 176, height: 118)
    color(0xF4F7FA).setFill()
    NSBezierPath(roundedRect: printer, xRadius: 22, yRadius: 22).fill()
    color(0x1C4C6E).setFill()
    NSBezierPath(roundedRect: CGRect(x: 724, y: 162, width: 128, height: 16), xRadius: 6, yRadius: 6).fill()
    color(0xD5DDE6).setFill()
    NSBezierPath(roundedRect: CGRect(x: 760, y: 124, width: 56, height: 22), xRadius: 6, yRadius: 6).fill()

    let label = CGRect(x: 292, y: 168, width: 440, height: 688)
    let shadow = NSShadow()
    shadow.shadowColor = color(0x07131C, alpha: 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.shadowBlurRadius = 28
    ctx.saveGState()
    shadow.set()
    color(0xFFFFFF).setFill()
    let card = NSBezierPath(roundedRect: label, xRadius: 28, yRadius: 28)
    card.fill()
    ctx.restoreGState()

    // Peeled corner. Clipped so the fold stays inside the label's rounded edge.
    ctx.saveGState()
    card.addClip()
    let peel = NSBezierPath()
    peel.move(to: CGPoint(x: label.maxX - 92, y: label.maxY))
    peel.line(to: CGPoint(x: label.maxX, y: label.maxY))
    peel.line(to: CGPoint(x: label.maxX, y: label.maxY - 92))
    peel.close()
    color(0xE4EAF0).setFill()
    peel.fill()
    let crease = NSBezierPath()
    crease.move(to: CGPoint(x: label.maxX - 92, y: label.maxY))
    crease.line(to: CGPoint(x: label.maxX, y: label.maxY - 92))
    color(0xC5D0DA).setStroke()
    crease.lineWidth = 3
    crease.stroke()
    ctx.restoreGState()

    // Address-style placeholder bars. Widths vary; there is no text.
    let bars: [(CGFloat, CGFloat)] = [
        (250, 22),
        (196, 16),
        (168, 16),
        (214, 16),
    ]
    var barY = label.maxY - 118
    for (width, height) in bars {
        color(0xD5DDE6).setFill()
        NSBezierPath(
            roundedRect: CGRect(x: label.minX + 48, y: barY, width: width, height: height),
            xRadius: height / 2,
            yRadius: height / 2
        ).fill()
        barY -= height + 22
    }

    // Barcode along the bottom of the label.
    let pattern: [CGFloat] = [4, 2, 8, 2, 3, 6, 2, 10, 2, 4, 7, 2, 3, 2, 9, 2, 5, 3, 2, 6, 2, 4]
    var x = label.minX + 46
    let codeBottom = label.minY + 58
    let codeTop: CGFloat = 118
    var dark = true
    for width in pattern {
        let scaled = width * 6.4
        if dark {
            color(0x1A2330).setFill()
            NSBezierPath(rect: CGRect(x: x, y: codeBottom, width: scaled, height: codeTop)).fill()
        }
        x += scaled
        dark.toggle()
        if x > label.maxX - 46 { break }
    }
}

func image(_ side: CGFloat, draw: () -> Void, sourceSide: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    let ctx = NSGraphicsContext.current?.cgContext
    ctx?.scaleBy(x: side / sourceSide, y: side / sourceSide)
    draw()
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        fputs("could not encode \(url.path)\n", stderr)
        exit(1)
    }
    try data.write(to: url)
}

func drawBackground() -> NSImage {
    let size = NSSize(width: 1240, height: 760)
    let image = NSImage(size: size)
    image.lockFocus()
    let bounds = NSRect(origin: .zero, size: size)
    let gradient = NSGradient(colors: [color(0xE7F1F6), color(0xF7FBFD), color(0xD5E6EF)])!
    gradient.draw(in: bounds, angle: -20)
    let tile = imageOfIcon(side: 280)
    tile.draw(
        in: NSRect(x: 860, y: 210, width: 280, height: 280),
        from: NSRect(origin: .zero, size: tile.size),
        operation: .sourceOver,
        fraction: 1
    )
    image.unlockFocus()
    return image
}

func imageOfIcon(side: CGFloat) -> NSImage {
    image(side, draw: drawLabelIcon, sourceSide: canvas)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try writePNG(imageOfIcon(side: 1024), to: out.appendingPathComponent("icon-1024.png"))
try writePNG(drawBackground(), to: out.appendingPathComponent("background.png"))
print("wrote \(out.path)")
