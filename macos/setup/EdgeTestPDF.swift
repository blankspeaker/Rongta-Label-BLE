// SPDX-License-Identifier: GPL-3.0-or-later
// Edge-outline PDF for a custom label size. Named sizes ship as files.
import Foundation

enum EdgeTestPDF {
    private static let mm = 72.0 / 25.4

    /// Custom.WxHin or Custom.WxHpt. Named PPD sizes are installed PDFs.
    static func render(pageSize: String) -> Data? {
        guard let spec = pageSpec(pageSize) else {
            return nil
        }
        return render(width: spec.0, height: spec.1, title: spec.2)
    }

    static func render(width: Double, height: Double, title: String) -> Data {
        let w = width
        let h = height
        let short = min(w, h)
        var ops: [String] = ["0 0 0 RG 0 0 0 rg 0 J"]

        func num(_ value: Double) -> String {
            String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, weight: Double = 0.5) {
            ops.append("\(num(weight)) w \(num(x1)) \(num(y1)) m \(num(x2)) \(num(y2)) l S")
        }
        func rect(_ x: Double, _ y: Double, _ rw: Double, _ rh: Double, _ weight: Double) {
            ops.append("\(num(weight)) w \(num(x)) \(num(y)) \(num(rw)) \(num(rh)) re S")
        }
        func escaped(_ raw: String) -> String {
            raw.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "(", with: "\\(")
                .replacingOccurrences(of: ")", with: "\\)")
        }
        func text(_ x: Double, _ y: Double, _ raw: String, _ size: Double) {
            ops.append("BT /F1 \(num(size)) Tf \(num(x)) \(num(y)) Td (\(escaped(raw))) Tj ET")
        }
        func textWidth(_ raw: String, _ size: Double) -> Double {
            Double(raw.count) * size * 0.55
        }
        func ctext(_ y: Double, _ raw: String, _ size: Double) {
            text((w - textWidth(raw, size)) / 2, y, raw, size)
        }

        rect(0.6, 0.6, w - 1.2, h - 1.2, 1.2)

        let tickFactor = min(1.0, (0.18 * short) / (6 * mm))
        var i = 1
        while Double(i) < w / mm {
            let base = i % 10 == 0 ? 6.0 : (i % 5 == 0 ? 4.0 : 2.0)
            let length = base * tickFactor * mm
            let x = Double(i) * mm
            line(x, 0, x, length)
            line(x, h, x, h - length)
            i += 1
        }
        i = 1
        while Double(i) < h / mm {
            let base = i % 10 == 0 ? 6.0 : (i % 5 == 0 ? 4.0 : 2.0)
            let length = base * tickFactor * mm
            let y = Double(i) * mm
            line(0, y, length, y)
            line(w, y, w - length, y)
            i += 1
        }

        if h >= 320 && w >= 250 {
            ops.append("[3 3] 0 d")
            rect(5 * mm, 5 * mm, w - 10 * mm, h - 10 * mm, 0.5)
            ops.append("[] 0 d")
            let arm = 15 * mm
            line(w / 2 - arm, h / 2, w / 2 + arm, h / 2, weight: 0.8)
            line(w / 2, h / 2 - arm, w / 2, h / 2 + arm, weight: 0.8)
            ctext(h - 14 * mm, "TOP", 12)
            ctext(10 * mm, "BOTTOM", 12)
            text(9 * mm, h / 2 - 4, "LEFT", 12)
            text(w - 9 * mm - textWidth("RIGHT", 12), h / 2 - 4, "RIGHT", 12)
            ctext(h / 2 + 22 * mm, title, 16)
            ctext(h / 2 - 27 * mm, "solid line = label edge", 9)
            ctext(h / 2 - 32 * mm, "dashed box = 5 mm in", 9)
            ctext(h / 2 - 37 * mm, "ticks every 1 mm from each edge", 9)
        } else {
            var titleSize = short >= 90 ? 16.0 : (short >= 70 ? 11.0 : 8.0)
            while titleSize > 6 && textWidth(title, titleSize) > w - 8 {
                titleSize -= 0.5
            }
            let titleY = h / 2 - titleSize * 0.35
            if short >= 38 * mm {
                ops.append("[3 3] 0 d")
                rect(5 * mm, 5 * mm, w - 10 * mm, h - 10 * mm, 0.5)
                ops.append("[] 0 d")
                let arm = min(15 * mm, short * 0.15)
                line(w / 2 - arm, h / 2, w / 2 + arm, h / 2, weight: 0.8)
                line(w / 2, h / 2 - arm, w / 2, h / 2 + arm, weight: 0.8)
                let side = short < 80 ? 9.0 : 12.0
                let topY = h - max(8 * mm, 6 * tickFactor * mm + side)
                let botY = max(4 * mm, 2 * tickFactor * mm + 2)
                if topY > titleY + titleSize + 4 && botY + side + 4 < titleY {
                    ctext(topY, "TOP", side)
                    ctext(botY, "BOTTOM", side)
                    let leftX = 4 * mm
                    let rightX = w - 4 * mm - textWidth("RIGHT", side)
                    let sideY = (titleY + botY) / 2
                    if rightX > leftX + textWidth("LEFT", side) + 8 {
                        text(leftX, sideY, "LEFT", side)
                        text(rightX, sideY, "RIGHT", side)
                    }
                }
            }
            if textWidth(title, titleSize) <= w - 4 {
                ctext(titleY, title, titleSize)
            }
        }

        let stream = Data(ops.joined(separator: "\n").utf8)
        let media = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(num(w)) \(num(h))] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data(media.utf8),
        ]
        var contents = Data("<< /Length \(stream.count) >>\nstream\n".utf8)
        contents.append(stream)
        contents.append(Data("\nendstream".utf8))
        objects.append(contents)
        objects.append(Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>".utf8))

        var out = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(index + 1) 0 obj\n".utf8))
            out.append(body)
            out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        out.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            out.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        out.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return out
    }

    private static func pageSpec(_ pageSize: String) -> (Double, Double, String)? {
        guard pageSize.hasPrefix("Custom.") else {
            return nil
        }
        var body = String(pageSize.dropFirst("Custom.".count))
        let points: Bool
        if body.hasSuffix("in") {
            body.removeLast(2)
            points = false
        } else if body.hasSuffix("pt") {
            body.removeLast(2)
            points = true
        } else {
            return nil
        }
        let parts = body.split(separator: "x", maxSplits: 1).map(String.init)
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0 else {
            return nil
        }
        let title = "\(SetupLogic.formatInches(width)) x \(SetupLogic.formatInches(height))\(points ? " pt" : "") EDGE TEST"
        if points {
            return (width, height, title)
        }
        return (width * 72.0, height * 72.0, title)
    }
}
