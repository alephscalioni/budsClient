#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$(python3 "$ROOT/scripts/assemble-source.py")"
xcodebuild -project "$SOURCE/GalaxyBudsClient.Platform.OSX/Native/NativeInterop.xcodeproj" \
    -scheme NativeInterop -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$ROOT/.build/xcode" \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
    -scmProvider system \
    CONFIGURATION_BUILD_DIR="$SOURCE/GalaxyBudsClient.Platform.OSX/Native/Build/Release" \
    MACOSX_DEPLOYMENT_TARGET=14.2 CODE_SIGNING_ALLOWED=NO build
