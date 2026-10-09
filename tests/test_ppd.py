#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Structural checks for the generated PPDs."""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PPD = ROOT / "ppd"

REQUIRED_SIZES = [
    "4x6in",
    "4x4in",
    "4x3in",
    "4x2in",
    "2x1in",
    "3x2in",
    "2.25x1.25in",
]

ZPL = {
    "Rongta_RP420_ZPL_203dpi.ppd": "Rongta RP420",
    "Rongta_RP421A_ZPL_203dpi.ppd": "Rongta RP421A",
    "Rongta_RP425_ZPL_203dpi.ppd": "Rongta RP425",
    "Rongta_ZPL_203dpi.ppd": "Rongta ZPL 203dpi",
}
TSPL = {
    "Rongta_RP422_TSPL_203dpi.ppd": "Rongta RP422",
    "Rongta_TSPL_203dpi.ppd": "Rongta TSPL 203dpi",
}


def fail(msg):
    print("FAIL", msg, file=sys.stderr)
    return 1


def main() -> int:
    errors = 0
    proc = subprocess.run(
        [sys.executable, str(ROOT / "ppd" / "gen_ppds.py"), "--check"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        errors += 1

    files = list(PPD.glob("*.ppd"))
    if len(files) != 6:
        errors += fail(f"expected 6 PPDs, found {len(files)}")

    for path in files:
        text = path.read_text(encoding="utf-8")
        if not text.startswith('*PPD-Adobe: "4.3"\n'):
            errors += fail(f"{path.name} missing header")
        if text.count("*OpenUI ") != text.count("*CloseUI:"):
            errors += fail(f"{path.name} unbalanced UI")
        for size in REQUIRED_SIZES:
            if f"*PageSize {size}/" not in text:
                errors += fail(f"{path.name} missing {size}")
        if "*DefaultResolution: 203dpi" not in text and "*Resolution 203dpi/" not in text:
            errors += fail(f"{path.name} missing 203 dpi")
        if '*Manufacturer: "Rongta"' not in text:
            errors += fail(f"{path.name} manufacturer")
        if "*DefaultrtLabelHomeX: 20" not in text or '*DefaultrtLabelTop: -20' not in text:
            errors += fail(f"{path.name} calibration defaults")
        if "rastertoRT" in text:
            errors += fail(f"{path.name} contains rastertoRT")
        opens = text.count("*OpenUI ")
        if opens < 8:
            errors += fail(f"{path.name} has too few options")

    def filter_line(text):
        for line in text.splitlines():
            if line.startswith("*cupsFilter:"):
                return line
        return ""

    for name, model in ZPL.items():
        text = (PPD / name).read_text(encoding="utf-8")
        if 'rastertozpl-rt"' not in filter_line(text):
            errors += fail(f"{name} should use rastertozpl-rt")
        if f'*ModelName: "{model}"' not in text:
            errors += fail(f"{name} model name")
        for key, default in (
            ("rtInsetLeft", "8"),
            ("rtInsetRight", "8"),
            ("rtInsetTop", "32"),
            ("rtInsetBottom", "0"),
        ):
            if f"*Default{key}: {default}\n" not in text:
                errors += fail(f"{name} default {key}")
    for name, model in TSPL.items():
        text = (PPD / name).read_text(encoding="utf-8")
        line = filter_line(text)
        if 'rastertotspl-rt"' not in line:
            errors += fail(f"{name} should use rastertotspl-rt")
        if f'*ModelName: "{model}"' not in text:
            errors += fail(f"{name} model name")
        if "rastertozpl-rt" in line:
            errors += fail(f"{name} should not use the ZPL filter")
        for key in ("rtInsetLeft", "rtInsetRight", "rtInsetTop", "rtInsetBottom"):
            if f"*Default{key}: 0\n" not in text:
                errors += fail(f"{name} default {key}")

    if errors:
        print(f"{errors} ppd failure(s)", file=sys.stderr)
        return 1
    print("ppd tests ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
