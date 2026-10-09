#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Remove the Rongta label driver and queues that use it.
if [ "$(id -u)" -ne 0 ]; then
  exec /usr/bin/sudo "$0" "$@"
fi

LABEL="com.blankspeaker.rongta-label"
APP="/Library/Application Support/com.blankspeaker.rongta-label"

for user in $(/usr/bin/who | /usr/bin/awk '{print $1}' | /usr/bin/sort -u); do
  uid=$(/usr/bin/id -u "$user" 2>/dev/null || true)
  if [ -n "$uid" ]; then
    /bin/launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
  fi
done

if [ -d /etc/cups/ppd ]; then
  for ppd in /etc/cups/ppd/*.ppd; do
    [ -f "$ppd" ] || continue
    if /usr/bin/grep -q 'rastertozpl-rt\|rastertotspl-rt' "$ppd" 2>/dev/null; then
      queue=$(basename "$ppd" .ppd)
      /usr/sbin/lpadmin -x "$queue" 2>/dev/null || true
    fi
  done
fi

/bin/rm -f "/Library/LaunchAgents/$LABEL.plist"
/bin/rm -f /usr/libexec/cups/backend/rongta-bt
/bin/rm -f /usr/libexec/cups/backend/rongta-ble
/bin/rm -f /usr/libexec/cups/filter/rastertozpl-rt
/bin/rm -f /usr/libexec/cups/filter/rastertotspl-rt
/bin/rm -f \
  /Library/Printers/PPDs/Contents/Resources/Rongta_RP420_ZPL_203dpi.ppd \
  /Library/Printers/PPDs/Contents/Resources/Rongta_RP421A_ZPL_203dpi.ppd \
  /Library/Printers/PPDs/Contents/Resources/Rongta_RP422_TSPL_203dpi.ppd \
  /Library/Printers/PPDs/Contents/Resources/Rongta_RP425_ZPL_203dpi.ppd \
  /Library/Printers/PPDs/Contents/Resources/Rongta_ZPL_203dpi.ppd \
  /Library/Printers/PPDs/Contents/Resources/Rongta_TSPL_203dpi.ppd
/bin/rm -rf "$APP"
/bin/rm -rf "/Applications/Rongta Label Setup.app"
/usr/sbin/pkgutil --forget "$LABEL" >/dev/null 2>&1 || true
echo "Rongta label driver removed."
