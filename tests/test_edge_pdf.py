#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Every PPD page size has an edge-test PDF with that MediaBox."""

import importlib.util
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ppd"))
from gen_ppds import SIZES  # noqa: E402


def load_edge():
    path = ROOT / "examples" / "edge-test.py"
    spec = importlib.util.spec_from_file_location("edge_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def mediabox(data: bytes):
    match = re.search(
        br"/MediaBox\s*\[\s*([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s*\]",
        data,
    )
    if match is None:
        return None
    return tuple(float(part) for part in match.groups())


def main() -> int:
    edge = load_edge()
    errors = 0
    if len(SIZES) != 15:
        print(f"FAIL expected 15 PPD sizes, found {len(SIZES)}", file=sys.stderr)
        errors += 1
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp)
        edge.write_named(dest)
        names = sorted(path.name for path in dest.glob("*.pdf"))
        if names != sorted(f"{key}.pdf" for key, _label, _w, _h in SIZES):
            print(f"FAIL edge-test names {names}", file=sys.stderr)
            errors += 1
        for key, label, width, height in SIZES:
            data = (dest / f"{key}.pdf").read_bytes()
            box = mediabox(data)
            expect = (0.0, 0.0, float(width), float(height))
            if box != expect:
                print(f"FAIL {key} MediaBox {box} != {expect}", file=sys.stderr)
                errors += 1
            title = edge.title_from_label(label).encode("ascii")
            if title not in data:
                print(f"FAIL {key} missing title", file=sys.stderr)
                errors += 1
        tall = (dest / "4x6in.pdf").read_bytes()
        small = (dest / "2x1in.pdf").read_bytes()
        if b"solid line = label edge" not in tall:
            print("FAIL 4x6 dropped the caption", file=sys.stderr)
            errors += 1
        if b"solid line = label edge" in small or b"(LEFT)" in small:
            print("FAIL 2x1 kept elements that do not fit", file=sys.stderr)
            errors += 1
        if b"(2 x 1 EDGE TEST)" not in small:
            print("FAIL 2x1 missing size label", file=sys.stderr)
            errors += 1
    width, height, title = edge.parse_page_size("Custom.3.5x2in")
    custom = edge.render_pdf(width, height, title)
    box = mediabox(custom)
    if box != (0.0, 0.0, 252.0, 144.0):
        print(f"FAIL custom MediaBox {box}", file=sys.stderr)
        errors += 1
    if title.encode("ascii") not in custom:
        print("FAIL custom title", file=sys.stderr)
        errors += 1
    fallback = (ROOT / "examples" / "edge-test.pdf").read_bytes()
    if mediabox(fallback) != (0.0, 0.0, 288.0, 432.0):
        print("FAIL edge-test.pdf is not the 4x6 page", file=sys.stderr)
        errors += 1
    if errors:
        print(f"{errors} edge-test failure(s)", file=sys.stderr)
        return 1
    print("edge-test pdfs ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
