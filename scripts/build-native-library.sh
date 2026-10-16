#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$(python3 "$ROOT/scripts/assemble-source.py")"
exec bash "$SOURCE/macOSAutoSwitch/scripts/build-native-library.sh"
