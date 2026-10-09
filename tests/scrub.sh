#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Fail on forbidden strings, home paths, or secret material.
# Extra fixed strings (one per line) come from $RONGTA_SCRUB_PATTERNS or
# tests/scrub-patterns.local. That file is gitignored. Blank lines and lines
# starting with # are ignored.
set -eu
cd "$(dirname "$0")/.."

fail=0
scan() {
  label=$1
  pattern=$2
  hits=/tmp/scrub-hit.txt
  : >"$hits"
  if command -v rg >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    rg -n -F --hidden \
      --glob '!.git/**' --glob '!uploads/**' --glob '!tests/scrub.sh' \
      --glob '!tests/scrub-patterns.local' --glob '!build/**' --glob '!dist/**' \
      --glob '!*.raster' \
      -e "$pattern" . >"$hits" 2>/dev/null || true
  else
    grep -R -n -I -F \
      --exclude-dir=.git --exclude-dir=uploads --exclude-dir=build --exclude-dir=dist \
      --exclude=scrub.sh --exclude=scrub-patterns.local --exclude='*.raster' \
      -e "$pattern" . >"$hits" 2>/dev/null || true
  fi
  if [ -s "$hits" ]; then
    echo "scrub: found $label" >&2
    cat "$hits" >&2
    fail=1
  fi
}

scan "retired filter name" "$(printf '%s%s' 'rasterto' 'RTM')"
scan "home path" "/Users/"
scan "retired helper" "$(printf '%s%s' 'listen' '.py')"
scan "retired ppd nickname" "$(printf '%s%s' 'RP420(ZPL' ' 203DPI)')"
scan "private key" "$(printf '%s%s' '-----BEGIN ' 'PRIVATE KEY-----')"
scan "openssh private key" "$(printf '%s%s' '-----BEGIN OPENSSH ' 'PRIVATE KEY-----')"
scan "rsa private key" "$(printf '%s%s' '-----BEGIN RSA ' 'PRIVATE KEY-----')"
scan "ec private key" "$(printf '%s%s' '-----BEGIN EC ' 'PRIVATE KEY-----')"
scan "github token" "$(printf '%s_' 'ghp')"
scan "github fine-grained token" "$(printf '%s_' 'github_pat')"
scan "slack token" "$(printf '%s-' 'xoxb')"

extra=""
if [ -n "${RONGTA_SCRUB_PATTERNS:-}" ]; then
  extra=$RONGTA_SCRUB_PATTERNS
elif [ -f tests/scrub-patterns.local ]; then
  extra=tests/scrub-patterns.local
fi
if [ -n "$extra" ]; then
  if [ ! -f "$extra" ]; then
    echo "scrub: RONGTA_SCRUB_PATTERNS is not a file: $extra" >&2
    exit 1
  fi
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    case $pattern in
      ''|'#'*) continue ;;
    esac
    scan "local pattern" "$pattern"
  done <"$extra"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "scrub ok"
