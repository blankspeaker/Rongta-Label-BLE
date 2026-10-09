#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build an unsigned universal macOS installer for the Rongta label driver.
# Run on macOS. Linux CI and development use `make test` instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
# This CLT defaults the deployment target to the current SDK, which would
# mark the filters macOS-27-only. Pin them to macOS 11. The Swift helper
# targets macOS 13: older targets autolink back-deploy archives that the
# tools ship only as arm64/arm64e, so the x86_64 slice does not link.
FILTER_MIN="11.0"
SWIFT_MIN="13.0"
BUILD="$ROOT/build/pkg"
DIST="$ROOT/dist"
SDK=""

if [ "$(uname -s)" != "Darwin" ]; then
  echo "build.sh creates a macOS .pkg and must run on macOS. On Linux, run: make test" >&2
  exit 1
fi

if ! command -v pkgbuild >/dev/null 2>&1 || ! command -v productbuild >/dev/null 2>&1; then
  echo "pkgbuild and productbuild are required (Xcode command line tools)." >&2
  exit 1
fi
if ! command -v swiftc >/dev/null 2>&1 || ! command -v clang >/dev/null 2>&1; then
  echo "clang and swiftc are required." >&2
  exit 1
fi

rm -rf "$BUILD"
mkdir -p "$BUILD" "$DIST"

if command -v xcrun >/dev/null 2>&1; then
  SDK="$(xcrun --show-sdk-path)"
fi

CUPS_CFLAGS=""
CUPS_LIBS="-lcups"
if command -v cups-config >/dev/null 2>&1; then
  CUPS_CFLAGS="$(cups-config --cflags || true)"
  CUPS_LIBS="$(cups-config --libs || true)"
elif [ -n "$SDK" ]; then
  CUPS_CFLAGS="-I${SDK}/usr/include"
  CUPS_LIBS="-L${SDK}/usr/lib -lcups"
fi
CUPS_LIBS="${CUPS_LIBS} -lz"

# Remap absolute paths so shipped binaries do not embed this machine's tree or home.
SWIFT_MAPS=(
  -file-prefix-map "$ROOT=."
  -debug-prefix-map "$ROOT=."
  -coverage-prefix-map "$ROOT=."
)
CLANG_MAPS=(
  "-ffile-prefix-map=$ROOT=."
  "-fdebug-prefix-map=$ROOT=."
  "-fcoverage-prefix-map=$ROOT=."
)
if [ -n "${HOME:-}" ]; then
  SWIFT_MAPS+=(
    -file-prefix-map "$HOME=/home"
    -debug-prefix-map "$HOME=/home"
    -coverage-prefix-map "$HOME=/home"
  )
  CLANG_MAPS+=(
    "-ffile-prefix-map=$HOME=/home"
    "-fdebug-prefix-map=$HOME=/home"
    "-fcoverage-prefix-map=$HOME=/home"
  )
fi

run_cc() {
  if [ -n "$SDK" ]; then
    # shellcheck disable=SC2086
    clang -isysroot "$SDK" "${CLANG_MAPS[@]}" $CUPS_CFLAGS "$@" $CUPS_LIBS
  else
    # shellcheck disable=SC2086
    clang "${CLANG_MAPS[@]}" $CUPS_CFLAGS "$@" $CUPS_LIBS
  fi
}

run_swift() {
  plist="$1"
  shift
  if [ -n "$SDK" ]; then
    swiftc -O -sdk "$SDK" "${SWIFT_MAPS[@]}" \
      -Xfrontend -no-serialize-debugging-options \
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$plist" \
      "$@"
  else
    swiftc -O "${SWIFT_MAPS[@]}" \
      -Xfrontend -no-serialize-debugging-options \
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$plist" \
      "$@"
  fi
}

compile_filter() {
  name="$1"
  src="$2"
  if run_cc -mmacosx-version-min="${FILTER_MIN}" -std=c11 -D_DEFAULT_SOURCE -O2 -Wall -Wextra -Werror -Isrc \
      -arch arm64 -arch x86_64 \
      "$ROOT/src/${src}" "$ROOT/src/encode.c" "$ROOT/src/raster_page.c" \
      -o "$BUILD/${name}"; then
    return 0
  fi
  echo "Universal build of ${name} failed; building for the host architecture." >&2
  run_cc -mmacosx-version-min="${FILTER_MIN}" -std=c11 -D_DEFAULT_SOURCE -O2 -Wall -Wextra -Werror -Isrc \
    "$ROOT/src/${src}" "$ROOT/src/encode.c" "$ROOT/src/raster_page.c" \
    -o "$BUILD/${name}"
}

compile_filter rastertozpl-rt rastertozpl-rt.c
compile_filter rastertotspl-rt rastertotspl-rt.c

# lipo drops a usable signature. Sign the finished binary once, with a stable
# identifier, so TCC does not key the grant on the slice filename.
sign_ble() {
  bin="$1"
  # Identifier-only designated requirement, not a cdhash. A later rebuild
  # with this same identifier still satisfies the Bluetooth grant.
  codesign -s - -f -i com.blankspeaker.rongta-label.ble \
    -r '=designated => identifier "com.blankspeaker.rongta-label.ble"' \
    "$bin"
  # Capture first. grep -q would SIGPIPE codesign and fail the script under pipefail.
  info="$(codesign -dvvv "$bin" 2>&1 || true)"
  req="$(codesign -d -r- "$bin" 2>&1 || true)"
  printf '%s\n' "$info" | grep -q 'Identifier=com.blankspeaker.rongta-label.ble'
  printf '%s\n' "$info" | grep -q 'Info.plist entries='
  printf '%s\n' "$req" | grep -F 'identifier "com.blankspeaker.rongta-label.ble"' >/dev/null
}

if run_swift "$ROOT/macos/Info.plist" -target "arm64-apple-macosx${SWIFT_MIN}" -o "$BUILD/rongta-ble-arm64" \
    "$ROOT/macos/BluetoothGate.swift" "$ROOT/macos/rongta-ble.swift" \
   && run_swift "$ROOT/macos/Info.plist" -target "x86_64-apple-macosx${SWIFT_MIN}" -o "$BUILD/rongta-ble-x86_64" \
    "$ROOT/macos/BluetoothGate.swift" "$ROOT/macos/rongta-ble.swift"; then
  lipo -create -output "$BUILD/rongta-ble" "$BUILD/rongta-ble-arm64" "$BUILD/rongta-ble-x86_64"
else
  host_arch="$(uname -m)"
  echo "Universal Swift build failed; building rongta-ble for ${host_arch}." >&2
  run_swift "$ROOT/macos/Info.plist" -target "${host_arch}-apple-macosx${SWIFT_MIN}" -o "$BUILD/rongta-ble" \
    "$ROOT/macos/BluetoothGate.swift" "$ROOT/macos/rongta-ble.swift"
fi
sign_ble "$BUILD/rongta-ble"

host_arch="$(uname -m)"
if [ -n "$SDK" ]; then
  swiftc -O -sdk "$SDK" -target "${host_arch}-apple-macosx${SWIFT_MIN}" \
    "${SWIFT_MAPS[@]}" \
    -Xfrontend -no-serialize-debugging-options \
    -o "$BUILD/setup-logic-test" \
    "$ROOT/macos/BluetoothGate.swift" \
    "$ROOT/macos/setup/SetupLogic.swift" \
    "$ROOT/macos/setup/EdgeTestPDF.swift" \
    "$ROOT/macos/setup/SetupLogicTests.swift"
else
  swiftc -O -target "${host_arch}-apple-macosx${SWIFT_MIN}" \
    "${SWIFT_MAPS[@]}" \
    -Xfrontend -no-serialize-debugging-options \
    -o "$BUILD/setup-logic-test" \
    "$ROOT/macos/BluetoothGate.swift" \
    "$ROOT/macos/setup/SetupLogic.swift" \
    "$ROOT/macos/setup/EdgeTestPDF.swift" \
    "$ROOT/macos/setup/SetupLogicTests.swift"
fi
"$BUILD/setup-logic-test"

compile_disclaim() {
  arch="$1"
  out="$2"
  if [ -n "$SDK" ]; then
    clang -isysroot "$SDK" "${CLANG_MAPS[@]}" -mmacosx-version-min="${SWIFT_MIN}" \
      -arch "$arch" -Wall -Wextra -Werror -c "$ROOT/macos/setup/spawn_disclaim.c" -o "$out"
  else
    clang "${CLANG_MAPS[@]}" -mmacosx-version-min="${SWIFT_MIN}" \
      -arch "$arch" -Wall -Wextra -Werror -c "$ROOT/macos/setup/spawn_disclaim.c" -o "$out"
  fi
}

SETUP_SOURCES=(
  "$ROOT/macos/setup/SetupLogic.swift"
  "$ROOT/macos/setup/EdgeTestPDF.swift"
  "$ROOT/macos/setup/AppModel.swift"
  "$ROOT/macos/setup/Views.swift"
  "$ROOT/macos/setup/RongtaLabelSetupApp.swift"
  "$ROOT/macos/setup/HelperSocket.swift"
)
# The app talks to the launchd helper. The disclaim object is only the fallback spawn.
if compile_disclaim arm64 "$BUILD/spawn_disclaim-arm64.o" \
   && compile_disclaim x86_64 "$BUILD/spawn_disclaim-x86_64.o" \
   && run_swift "$ROOT/macos/setup/Info.plist" -parse-as-library -target "arm64-apple-macosx${SWIFT_MIN}" \
    -o "$BUILD/setup-arm64" "${SETUP_SOURCES[@]}" "$BUILD/spawn_disclaim-arm64.o" \
   && run_swift "$ROOT/macos/setup/Info.plist" -parse-as-library -target "x86_64-apple-macosx${SWIFT_MIN}" \
    -o "$BUILD/setup-x86_64" "${SETUP_SOURCES[@]}" "$BUILD/spawn_disclaim-x86_64.o"; then
  lipo -create -output "$BUILD/RongtaLabelSetup" "$BUILD/setup-arm64" "$BUILD/setup-x86_64"
else
  echo "Universal setup app failed; building for ${host_arch}." >&2
  compile_disclaim "${host_arch}" "$BUILD/spawn_disclaim.o"
  run_swift "$ROOT/macos/setup/Info.plist" -parse-as-library -target "${host_arch}-apple-macosx${SWIFT_MIN}" \
    -o "$BUILD/RongtaLabelSetup" "${SETUP_SOURCES[@]}" "$BUILD/spawn_disclaim.o"
fi

SETUP_APP="$BUILD/Rongta Label Setup.app"
rm -rf "$SETUP_APP"
mkdir -p "$SETUP_APP/Contents/MacOS" "$SETUP_APP/Contents/Resources"
cp "$BUILD/RongtaLabelSetup" "$SETUP_APP/Contents/MacOS/RongtaLabelSetup"
cp "$ROOT/macos/setup/Info.plist" "$SETUP_APP/Contents/Info.plist"
printf 'APPL????' > "$SETUP_APP/Contents/PkgInfo"
chmod 755 "$SETUP_APP/Contents/MacOS/RongtaLabelSetup"
# Shipping-label icon, drawn at build time. No checked-in artwork.
if [ -n "$SDK" ]; then
  swiftc -O -sdk "$SDK" "${SWIFT_MAPS[@]}" \
    -Xfrontend -no-serialize-debugging-options \
    -target "${host_arch}-apple-macosx${SWIFT_MIN}" \
    -o "$BUILD/draw-icon" "$ROOT/macos/icon/draw_icon.swift"
else
  swiftc -O "${SWIFT_MAPS[@]}" \
    -Xfrontend -no-serialize-debugging-options \
    -target "${host_arch}-apple-macosx${SWIFT_MIN}" \
    -o "$BUILD/draw-icon" "$ROOT/macos/icon/draw_icon.swift"
fi
"$BUILD/draw-icon" "$BUILD/iconart"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
icon_png() {
  px="$1"
  name="$2"
  sips -z "$px" "$px" "$BUILD/iconart/icon-1024.png" --out "$ICONSET/$name" >/dev/null
}
icon_png 16 icon_16x16.png
icon_png 32 "icon_16x16@2x.png"
icon_png 32 icon_32x32.png
icon_png 64 "icon_32x32@2x.png"
icon_png 128 icon_128x128.png
icon_png 256 "icon_128x128@2x.png"
icon_png 256 icon_256x256.png
icon_png 512 "icon_256x256@2x.png"
icon_png 512 icon_512x512.png
icon_png 1024 "icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$SETUP_APP/Contents/Resources/AppIcon.icns"
# The linker signs each slice with the intermediate filename. Re-seal the
# bundle ad hoc so the identifier is the one in Info.plist. This is not a
# Developer ID signature. The icon is already in Resources, so the seal covers it.
codesign -s - -f "$SETUP_APP"

python3 "$ROOT/ppd/gen_ppds.py" --check
python3 "$ROOT/examples/edge-test.py"

PAYLOAD="$BUILD/payload"
APP="$PAYLOAD/Library/Application Support/com.blankspeaker.rongta-label"
PPD_DST="$PAYLOAD/Library/Printers/PPDs/Contents/Resources"
mkdir -p \
  "$PAYLOAD/usr/libexec/cups/filter" \
  "$PAYLOAD/usr/libexec/cups/backend" \
  "$PAYLOAD/Library/LaunchAgents" \
  "$PAYLOAD/Applications" \
  "$PPD_DST" \
  "$APP"

cp "$BUILD/rastertozpl-rt" "$BUILD/rastertotspl-rt" "$PAYLOAD/usr/libexec/cups/filter/"
cp "$ROOT/macos/rongta-bt" "$PAYLOAD/usr/libexec/cups/backend/rongta-bt"
cp "$BUILD/rongta-ble" "$PAYLOAD/usr/libexec/cups/backend/rongta-ble"
cp "$BUILD/rongta-ble" "$APP/rongta-ble"
cp "$ROOT/macos/rongta-testprint" "$APP/rongta-testprint"
cp "$ROOT/examples/edge-test.pdf" "$APP/edge-test.pdf"
cp "$ROOT/examples/edge-test.py" "$APP/edge-test.py"
mkdir -p "$APP/edge-tests"
cp "$ROOT/examples/edge-tests/"*.pdf "$APP/edge-tests/"
cp "$ROOT/macos/uninstall.sh" "$APP/uninstall.sh"
cp "$ROOT/README.md" "$ROOT/LICENSE" "$APP/"
cp "$ROOT/ppd/"*.ppd "$PPD_DST/"
cp "$ROOT/macos/com.blankspeaker.rongta-label.plist" \
  "$PAYLOAD/Library/LaunchAgents/com.blankspeaker.rongta-label.plist"
cp -R "$SETUP_APP" "$PAYLOAD/Applications/"
chmod 755 "$PAYLOAD/usr/libexec/cups/filter/"* \
  "$PAYLOAD/usr/libexec/cups/backend/rongta-bt" \
  "$PAYLOAD/usr/libexec/cups/backend/rongta-ble" \
  "$APP/rongta-ble" "$APP/rongta-testprint" "$APP/uninstall.sh"
chmod 644 "$APP/edge-test.pdf" "$APP/edge-test.py" "$APP/edge-tests/"*.pdf
chmod 755 "$APP/edge-tests"

mkdir -p "$BUILD/scripts" "$BUILD/resources"
cp "$ROOT/macos/scripts/preinstall" "$ROOT/macos/scripts/postinstall" "$BUILD/scripts/"
chmod 755 "$BUILD/scripts/preinstall" "$BUILD/scripts/postinstall"
cp "$ROOT/macos/resources/welcome.rtf" "$BUILD/resources/"
cp "$ROOT/LICENSE" "$BUILD/resources/license.txt"
cp "$BUILD/iconart/background.png" "$BUILD/resources/background.png"

pkgbuild \
  --root "$PAYLOAD" \
  --scripts "$BUILD/scripts" \
  --identifier com.blankspeaker.rongta-label \
  --version "$VERSION" \
  --install-location / \
  "$BUILD/rongta-label-component.pkg"

productbuild \
  --distribution "$ROOT/macos/Distribution" \
  --resources "$BUILD/resources" \
  --package-path "$BUILD" \
  "$DIST/Rongta-Label-BLE.pkg"

echo "Built $DIST/Rongta-Label-BLE.pkg"
lipo -info "$BUILD/rongta-ble" "$SETUP_APP/Contents/MacOS/RongtaLabelSetup" || true
file "$BUILD/rastertozpl-rt" "$BUILD/rastertotspl-rt" || true
