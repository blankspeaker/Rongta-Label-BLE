# Rongta-Label-BLE

by [blankspeaker](https://x.com/blankspeaker) and [Grok Bot](https://x.ai/bot)

Print to a Rongta label printer from any Mac app, over Bluetooth LE. Version 1.0.0.

Not affiliated with or endorsed by Rongta. Rongta, ZPL (Zebra), TSPL (TSC) and Bluetooth are trademarks of their respective owners.

License: GPL-3.0-or-later. Copyright (C) 2026 blankspeaker (x.com/blankspeaker) and Grok Bot (x.ai/bot). The full text is in `LICENSE`.

## Download

[Download Rongta-Label-BLE.pkg](https://github.com/blankspeaker/Rongta-Label-BLE/releases/latest/download/Rongta-Label-BLE.pkg) from the [latest release](https://github.com/blankspeaker/Rongta-Label-BLE/releases/latest).

## Install

The package is unsigned.

1. Download `Rongta-Label-BLE.pkg`.
2. Control-click the package, choose Open, then Open again. If macOS still blocks it, allow it in Privacy & Security.
3. Click Continue, then Install. macOS asks for your password.
4. When the installer finishes, Rongta Label Setup opens.

If Gatekeeper blocks the app later, Control-click Rongta Label Setup, choose Open, then Open again.

## Add your printer

Turn the printer on and keep it close. Leave it unpaired in Bluetooth settings. Pairing there makes the connection less reliable.

1. In Rongta Label Setup, stay on Printer.
2. Pick your printer from the list. If several are nearby, choose the one you want. A printer you already added is marked Already added.
3. Click Add Printer. macOS asks for your password. The new printer becomes the default, at 4×6 inches.
4. Print a test label if you want. It can take up to 30 seconds. The app says "Done! Check your printer." when the label has been sent.

To add a second printer, click Add another printer. Show all Bluetooth devices, off by default, lists other nearby radios under "May not be a Rongta printer." Pick a model for one of those before you add it. Devices stay in the list until you click Search again or open Add Printer again. The list scrolls inside its own box.

## Supported printers

203 dpi only. 300 dpi heads are not supported.

| Printer | Language |
| --- | --- |
| RP420 | ZPL |
| RP421A | ZPL |
| RP425 | ZPL |
| Other Rongta ZPL 203 dpi | ZPL |
| RP422 | TSPL |
| Other Rongta TSPL 203 dpi | TSPL |

Label sizes: 4×6, 4×5, 4×4, 4×3, 4×2, 4×1, 4×6.5, 4×13, 3×3, 3×2, 3×1.25, 3×1, 2.25×1.25, 2×1, and 100×150 mm, plus a custom size. The default is 4×6 in.

Paper & Settings is where you change the size, the media (gap, continuous, or black mark), darkness, speed, and how photos are drawn. Save, and the queue keeps those choices.

## Calibrate

Print a test label from Calibrate. The outline is the true edge of the label.

On the printout, each side asks how many millimetres the solid line is cut off, or how wide the white gap is. The steppers move in half-millimetre steps. Save, then print again to check. Reset puts the margins back to this driver's defaults.

## Uninstall

In Rongta Label Setup, open Help and click Uninstall Rongta Label Setup. macOS asks for your password. That removes the app, the driver, and the queues that use it.

## Troubleshooting

**Bluetooth permission.** If the app cannot see the printer, open System Settings → Privacy & Security → Bluetooth. Allow Rongta Label Setup. If the list says rongta-ble, allow that too. It is the program that scans and prints. Then click Search again.

**The printer is missing.** Turn it on, keep it close, and click Search again. Show all Bluetooth devices if the name does not look like a Rongta model.

**Turn printer back on.** If a job stops because the printer needs attention, the app shows that message and a Turn printer back on button. Press it after you have cleared the printer, then print again.

**The test label is slow.** Bluetooth can take up to 30 seconds. Wait for "Done! Check your printer." before you print another.

## Building from source

See [docs/BUILDING.md](docs/BUILDING.md).
