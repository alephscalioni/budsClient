#!/bin/bash
# Fetch only the pinned upstream updater. Its release archive is hash verified.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARENT="$(cd "$ROOT/.." && pwd)"
DEST="$PARENT/tools/sparkle-2.10.0"
ARCHIVE="$DEST/Sparkle-2.10.0.tar.xz"
EXPECTED="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
mkdir -p "$DEST"
if [[ ! -f "$ARCHIVE" ]]; then
    /usr/bin/curl --fail --location --retry 2 --silent --show-error \
        'https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz' \
        --output "$ARCHIVE.download"
    [[ "$(/usr/bin/shasum -a 256 "$ARCHIVE.download" | cut -d ' ' -f 1)" == "$EXPECTED" ]] || { printf 'Sparkle checksum mismatch\n' >&2; exit 1; }
    mv "$ARCHIVE.download" "$ARCHIVE"
fi
[[ "$(/usr/bin/shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)" == "$EXPECTED" ]] || { printf 'Sparkle checksum mismatch\n' >&2; exit 1; }
/usr/bin/tar -xJf "$ARCHIVE" -C "$DEST" './Sparkle.framework' './bin' './LICENSE'
/usr/bin/codesign --verify --deep --strict "$DEST/Sparkle.framework"
