#!/bin/bash
# Assemble and invoke the preserved packager. This builds/signs; never launches.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$(python3 "$ROOT/scripts/assemble-source.py")"
if [[ -z "${BUDS_DOTNET:-}" ]]; then
    if command -v dotnet >/dev/null 2>&1; then
        BUDS_DOTNET="$(command -v dotnet)"
    elif [[ -x "$ROOT/.build/tools/dotnet/dotnet" ]]; then
        BUDS_DOTNET="$ROOT/.build/tools/dotnet/dotnet"
    else
        printf 'Set BUDS_DOTNET to an installed .NET SDK 10.0.300.\n' >&2
        exit 1
    fi
fi
export BUDS_DOTNET
bash "$ROOT/scripts/build-native-interop.sh"
export BUDS_DIST="$ROOT/dist"
exec bash "$SOURCE/scripts/build-buds-macos.sh"
