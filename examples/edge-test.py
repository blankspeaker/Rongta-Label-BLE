#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write an edge-outline PDF for every PPD page size.

The outline sits on the true page edge. The driver inset, not this file,
pulls the artwork in on the printer. Small labels keep the outline, the
millimetre ticks, and a size label, and drop captions that would collide.
"""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_sizes():
    """Named sizes come from the repo generator. An installed copy only needs Custom.*."""
    try:
        from gen_ppds import SIZES as sizes
        return list(sizes)
    except ImportError:
        pass
    sys.path.insert(0, str(ROOT / "ppd"))
    try:
        from gen_ppds import SIZES as sizes
        return list(sizes)
    except ImportError:
        return []


SIZES = load_sizes()

MM = 72 / 25.4
HERE = Path(__file__).resolve().parent


def title_from_label(label: str) -> str:
    text = label
    for suffix in (" in", " mm"):
        if text.endswith(suffix):
            text = text[: -len(suffix)]
            break
    return f"{text} EDGE TEST"


def format_number(value: float) -> str:
    if abs(value - round(value)) < 1e-6:
        return str(int(round(value)))
    text = f"{value:.2f}".rstrip("0").rstrip(".")
    return text


def parse_page_size(text: str):
    for key, label, width, height in SIZES:
        if text == key:
            return float(width), float(height), title_from_label(label)
    if not text.startswith("Custom."):
        raise ValueError(text)
    body = text[len("Custom.") :]
    unit = "in"
    if body.endswith("in"):
        body = body[:-2]
    elif body.endswith("pt"):
        body = body[:-2]
        unit = "pt"
    else:
        raise ValueError(text)
    width_s, height_s = body.split("x", 1)
    width = float(width_s)
    height = float(height_s)
    if unit == "in":
        title = f"{format_number(width)} x {format_number(height)} EDGE TEST"
        return width * 72.0, height * 72.0, title
    title = f"{format_number(width)} x {format_number(height)} pt EDGE TEST"
    return width, height, title


def pdf_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def render_pdf(width: float, height: float, title: str) -> bytes:
    w = float(width)
    h = float(height)
    short = min(w, h)
    ops = ["0 0 0 RG 0 0 0 rg 0 J"]

    def line(x1, y1, x2, y2, weight=0.5):
        ops.append(f"{weight} w {x1:.2f} {y1:.2f} m {x2:.2f} {y2:.2f} l S")

    def rect(x, y, rw, rh, weight):
        ops.append(f"{weight} w {x:.2f} {y:.2f} {rw:.2f} {rh:.2f} re S")

    def text(x, y, raw, size):
        ops.append(f"BT /F1 {size:.2f} Tf {x:.2f} {y:.2f} Td ({pdf_escape(raw)}) Tj ET")

    def text_width(raw, size):
        return len(raw) * size * 0.55

    def ctext(y, raw, size):
        text((w - text_width(raw, size)) / 2, y, raw, size)

    # Outline on the true page edge.
    rect(0.6, 0.6, w - 1.2, h - 1.2, 1.2)

    # Longest tick stays inside 18% of the short side, so 4x6 keeps 6/4/2 mm.
    tick_factor = min(1.0, (0.18 * short) / (6 * MM))
    for i in range(1, int(w / MM)):
        base = 6 if i % 10 == 0 else (4 if i % 5 == 0 else 2)
        length = base * tick_factor * MM
        x = i * MM
        line(x, 0, x, length)
        line(x, h, x, h - length)
    for i in range(1, int(h / MM)):
        base = 6 if i % 10 == 0 else (4 if i % 5 == 0 else 2)
        length = base * tick_factor * MM
        y = i * MM
        line(0, y, length, y)
        line(w, y, w - length, y)

    # Tall pages use the original 4x6 arrangement. Shorter ones drop what collides.
    if h >= 320 and w >= 250:
        ops.append("[3 3] 0 d")
        rect(5 * MM, 5 * MM, w - 10 * MM, h - 10 * MM, 0.5)
        ops.append("[] 0 d")
        arm = 15 * MM
        line(w / 2 - arm, h / 2, w / 2 + arm, h / 2, 0.8)
        line(w / 2, h / 2 - arm, w / 2, h / 2 + arm, 0.8)
        ctext(h - 14 * MM, "TOP", 12)
        ctext(10 * MM, "BOTTOM", 12)
        text(9 * MM, h / 2 - 4, "LEFT", 12)
        text(w - 9 * MM - text_width("RIGHT", 12), h / 2 - 4, "RIGHT", 12)
        ctext(h / 2 + 22 * MM, title, 16)
        ctext(h / 2 - 27 * MM, "solid line = label edge", 9)
        ctext(h / 2 - 32 * MM, "dashed box = 5 mm in", 9)
        ctext(h / 2 - 37 * MM, "ticks every 1 mm from each edge", 9)
    else:
        title_size = 16.0 if short >= 90 else (11.0 if short >= 70 else 8.0)
        while title_size > 6 and text_width(title, title_size) > w - 8:
            title_size -= 0.5
        title_y = h / 2 - title_size * 0.35
        if short >= 38 * MM:
            ops.append("[3 3] 0 d")
            rect(5 * MM, 5 * MM, w - 10 * MM, h - 10 * MM, 0.5)
            ops.append("[] 0 d")
            arm = min(15 * MM, short * 0.15)
            line(w / 2 - arm, h / 2, w / 2 + arm, h / 2, 0.8)
            line(w / 2, h / 2 - arm, w / 2, h / 2 + arm, 0.8)
            side = 9.0 if short < 80 else 12.0
            top_y = h - max(8 * MM, 6 * tick_factor * MM + side)
            bot_y = max(4 * MM, 2 * tick_factor * MM + 2)
            if top_y > title_y + title_size + 4 and bot_y + side + 4 < title_y:
                ctext(top_y, "TOP", side)
                ctext(bot_y, "BOTTOM", side)
                left_x = 4 * MM
                right_x = w - 4 * MM - text_width("RIGHT", side)
                side_y = (title_y + bot_y) / 2
                if right_x > left_x + text_width("LEFT", side) + 8:
                    text(left_x, side_y, "LEFT", side)
                    text(right_x, side_y, "RIGHT", side)
        if text_width(title, title_size) <= w - 4:
            ctext(title_y, title, title_size)

    stream = "\n".join(ops).encode("ascii")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {w:.2f} {h:.2f}] "
            f"/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"
        ).encode("ascii"),
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for index, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{index} 0 obj\n".encode("ascii") + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode("ascii")
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode("ascii")
    out += (
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
        f"startxref\n{xref}\n%%EOF\n"
    ).encode("ascii")
    return bytes(out)


def write_named(directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    for key, label, width, height in SIZES:
        data = render_pdf(width, height, title_from_label(label))
        (directory / f"{key}.pdf").write_bytes(data)
        if key == "4x6in":
            (HERE / "edge-test.pdf").write_bytes(data)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--page-size", help="PPD size such as 2x1in, or Custom.3.5x2in")
    parser.add_argument("--output", "-o", type=Path, help="write one PDF here")
    args = parser.parse_args(argv)
    if args.page_size:
        width, height, title = parse_page_size(args.page_size)
        data = render_pdf(width, height, title)
        if args.output is None:
            sys.stdout.buffer.write(data)
        else:
            args.output.write_bytes(data)
            print(f"wrote {args.output} ({len(data)} bytes)")
        return 0
    if not SIZES:
        print("edge-test.py needs ppd/gen_ppds.py to write every size", file=sys.stderr)
        return 1
    dest = HERE / "edge-tests"
    write_named(dest)
    print(f"wrote {len(SIZES)} pages in {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
