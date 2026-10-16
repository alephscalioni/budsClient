#!/bin/bash
# Build the embedded native library and package locally; never launch the app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARENT="$(cd "$ROOT/.." && pwd)"
DOTNET="${BUDS_DOTNET:-$PARENT/tools/dotnet/dotnet}"
DIST="${BUDS_DIST:-$PARENT/dist}"
APP="$DIST/Buds.app"
NATIVE="$ROOT/macOSAutoSwitch/dist/libBudsNative.dylib"
BLUETOOTH="$ROOT/GalaxyBudsClient.Platform.OSX/Native/Build/Release/libNativeInterop.dylib"
IMAGES="$ROOT/GalaxyBudsClient/Resources/Device/Realistic"
HELPER_SOURCES=(
    "$ROOT/macOSAutoSwitch/Tools/BudsGuardHelperMain.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/SpeakerGuard.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/MacAudio.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/MacPlaybackProcessActivity.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/NativeCommandRunner.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/NativeBudsLinkObserverHelper.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/NativeBudsSettingsHelper.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/NativeBudsSettingsOutput.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/NativeBudsSettingsWire.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/NativeBudsToolsPacket.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/NativeBudsTransport.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/NativeBudsSettingsOpen.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/NativeBudsSettingsOpenSDK.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/NativeBudsSDKWriter.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/NativeSerialChannelWriter.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/NativeSDKSerialExecutor.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/NativeBudsOperationDrain.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/NativeBudsOpeningPolicy.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/NativeBudsWriteTracker.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/SamsungMdePacket.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/SamsungBudsSettingsPacket.swift"
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/SamsungBudsSetting.swift"
)
ICON="$ROOT/macOSAutoSwitch/Resources/Buds.icns"
SIGNER="$ROOT/macOSAutoSwitch/scripts/sign-account-research.py"
CONFIGURATION="${CONFIGURATION:-Release}"
BUDS_RUNTIME_VERSION="${BUDS_RUNTIME_VERSION:-10.0.13}"
MARKER="local-buds-packaging-v1"

fail() { printf 'Buds packaging: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail 'macOS is required.'
case "$CONFIGURATION" in Debug|Release) ;; *) fail 'CONFIGURATION must be Debug or Release.' ;; esac
python3 - "$BUDS_RUNTIME_VERSION" <<'PY'
import re,sys
v=sys.argv[1]
if not re.fullmatch(r'10\.0\.[0-9]+',v) or tuple(map(int,v.split('.'))) < (10,0,13):
    raise SystemExit('Use a stable .NET 10 runtime at least 10.0.13.')
PY
# Never replace code while the owning app or audio-recovery journal is active.
/usr/bin/swift -e 'import AppKit; if !NSRunningApplication.runningApplications(withBundleIdentifier: "me.timschneeberger.galaxybudsclient").isEmpty { exit(2) }' \
    || fail 'Close Buds before packaging; the running app was preserved.'
[[ ! -e "$HOME/Library/Application Support/BudsAutoSwitch/SpeakerGuard/recovery.json" ]] \
    || fail 'Finish audio recovery before packaging; its journal was preserved.'
# Fail before publish, directory creation, signing, or replacement if inputs are absent.
for input in "$BLUETOOTH" "$ICON" "$SIGNER" "${HELPER_SOURCES[@]}"; do
    [[ -f "$input" ]] || fail "Missing input: $input"
done
[[ -d "$IMAGES" ]] || fail "Missing native resources: $IMAGES"
# HUD resource names are <iconPrefix>-0.png and <iconPrefix>-1.png.
IMAGE_FILES=("$IMAGES"/*.png)
[[ -f "${IMAGE_FILES[0]}" ]] || fail "No device images: $IMAGES"
[[ -x "$DOTNET" ]] || fail "Missing local SDK: $DOTNET"
[[ "$("$DOTNET" --version)" == 10.0.300 ]] || fail 'Expected local SDK 10.0.300.'
# Always compile the Swift sources being packaged. Reusing a previously built
# dylib silently shipped stale controller code even after managed publish passed.
bash "$ROOT/macOSAutoSwitch/scripts/build-native-library.sh"
for input in "$NATIVE" "$BLUETOOTH"; do
    /usr/bin/lipo "$input" -verify_arch arm64 || fail "No arm64 slice: $input"
done
if [[ -e "$APP" || -L "$APP" ]]; then
    [[ ! -L "$APP" && -d "$APP" && -f "$APP/Contents/Resources/.buds-packaging-owned" ]] \
        || fail "Refusing to replace an app not created by this script: $APP"
    [[ "$(cat "$APP/Contents/Resources/.buds-packaging-owned")" == "$MARKER" ]] \
        || fail 'Unrecognized packaging ownership marker.'
fi

mkdir -p "$DIST"
WORK="$(mktemp -d "$DIST/.buds-packaging.XXXXXX")"
cleanup() {
    # Restore the previous generated bundle if the final move failed.
    if [[ -d "$WORK/previous-Buds.app" && ! -e "$APP" ]]; then
        mv "$WORK/previous-Buds.app" "$APP"
    fi
    rm -rf -- "$WORK" # Only this invocation's temporary build artifacts.
}
trap cleanup EXIT
STAGED="$WORK/Buds.app"
MACOS="$STAGED/Contents/MacOS"
RESOURCES="$STAGED/Contents/Resources"
mkdir -p "$MACOS" "$RESOURCES"
mkdir -p "$STAGED/Contents/Frameworks"
/usr/bin/ditto "$PARENT/tools/sparkle-2.10.0/Sparkle.framework" "$STAGED/Contents/Frameworks/Sparkle.framework"
/usr/bin/ditto "$PARENT/tools/sparkle-2.10.0/LICENSE" "$RESOURCES/Sparkle-LICENSE.txt"

# Build the headless watchdog from current sources, never from a companion app.
# Compile and verify before publish; failure leaves the previous bundle intact.
xcrun swiftc -O -parse-as-library -D BUDS_EMBEDDED \
    -target arm64-apple-macos14.2 -module-cache-path "$WORK/SwiftModuleCache" \
    -framework Foundation -framework AppKit -framework CoreAudio -framework IOBluetooth \
    "${HELPER_SOURCES[@]}" -o "$WORK/BudsGuardHelper"
/usr/bin/lipo "$WORK/BudsGuardHelper" -verify_arch arm64 \
    || fail 'BudsGuardHelper has no arm64 slice.'

# Record managed inputs before the compiler runs. A concurrent edit cannot make
# BuildInfo describe source newer than the actual DLLs we are about to ship.
python3 - "$ROOT" "$WORK/managed-inputs.json" <<'PY'
from pathlib import Path
import hashlib,json,sys
root=Path(sys.argv[1]);blocked={'bin','obj','.git','node_modules','macOSAutoSwitch','reports','artifacts'}
files=[p for p in root.rglob('*') if p.is_file() and not blocked.intersection(p.relative_to(root).parts)
       and p.suffix in {'.cs','.axaml','.csproj','.props','.targets','.resx'}]
Path(sys.argv[2]).write_text(json.dumps({str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)},sort_keys=True))
PY
"$DOTNET" publish "$ROOT/GalaxyBudsClient/GalaxyBudsClient.csproj" \
    --configuration "$CONFIGURATION" --framework net10.0 \
    --runtime osx-arm64 --self-contained true --output "$WORK/publish" \
    -p:UseMacOSSDK=false -p:PackNative=true -p:UseAppHost=true \
    -p:PublishSingleFile=false -p:PublishTrimmed=false \
    -p:RuntimeFrameworkVersion="$BUDS_RUNTIME_VERSION" -p:TargetLatestRuntimePatch=false
python3 - "$ROOT" "$WORK/managed-inputs.json" "$WORK/publish/Galaxy Buds Manager.runtimeconfig.json" "$BUDS_RUNTIME_VERSION" <<'PY'
from pathlib import Path
import hashlib,json,sys
root=Path(sys.argv[1]);expected=json.loads(Path(sys.argv[2]).read_text());blocked={'bin','obj','.git','node_modules','macOSAutoSwitch','reports','artifacts'}
files=[p for p in root.rglob('*') if p.is_file() and not blocked.intersection(p.relative_to(root).parts)
       and p.suffix in {'.cs','.axaml','.csproj','.props','.targets','.resx'}]
actual={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}
if actual!=expected:raise SystemExit('Managed inputs changed during publish; previous application preserved. Rebuild after source work settles.')
runtime=json.loads(Path(sys.argv[3]).read_text()).get('runtimeOptions',{})
if not any(f.get('name')=='Microsoft.NETCore.App' and f.get('version')==sys.argv[4] for f in runtime.get('includedFrameworks',[])):
    raise SystemExit('Published self-contained runtime does not match the requested patched version.')
PY

# The csproj can publish the old helper app as AutoSwitch content. Do not bundle
# that second app: its native features and images are packaged directly below.
shopt -s dotglob nullglob
for item in "$WORK/publish/"*; do
    [[ "$(basename "$item")" == AutoSwitch ]] && continue
    /usr/bin/ditto "$item" "$MACOS/$(basename "$item")"
done
[[ -x "$MACOS/Galaxy Buds Manager" ]] || fail 'Publish did not produce the apphost.'
[[ -f "$MACOS/libhostfxr.dylib" && -f "$MACOS/libcoreclr.dylib" ]] \
    || fail 'Publish is missing the self-contained .NET runtime.'
/usr/bin/ditto "$NATIVE" "$MACOS/libBudsNative.dylib"
# Preserve the real Bluetooth interop library under its existing P/Invoke name.
/usr/bin/ditto "$BLUETOOTH" "$MACOS/libNativeInterop.dylib"
mkdir -p "$RESOURCES/BudsImages"
for image in "${IMAGE_FILES[@]}"; do
    /usr/bin/ditto "$image" "$RESOURCES/BudsImages/$(basename "$image")"
done
/usr/bin/ditto "$ICON" "$RESOURCES/Buds.icns"
# Build the interpreted fallback from these same sources, rather than copying
# an observer from an older standalone companion build.
cat "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/MacPlaybackIntent.swift" \
    "$ROOT/macOSAutoSwitch/Sources/BudsAutoSwitch/MacPlaybackProcessActivity.swift" \
    "$ROOT/macOSAutoSwitch/scripts/PlaybackObserverMain.swift" > "$RESOURCES/PlaybackObserver.swift"
# This resource executes separately from the native library. A full app build
# cannot catch a missing dependency in its concatenated interpreter source.
xcrun swiftc -typecheck -target arm64-apple-macos14.2 \
    -module-cache-path "$WORK/SwiftModuleCache" "$RESOURCES/PlaybackObserver.swift"
/usr/bin/ditto "$WORK/BudsGuardHelper" "$MACOS/BudsGuardHelper"
printf '%s\n' "$MARKER" > "$RESOURCES/.buds-packaging-owned"

# macOS treats regular files under Contents/MacOS as code. Keep managed
# assemblies/data under Resources and retain sibling links for the .NET host.
python3 - "$STAGED" <<'PYDATA'
from pathlib import Path
import os, shutil, sys
app = Path(sys.argv[1]); macos = app / 'Contents/MacOS'; payload = app / 'Contents/Resources/Managed'
magic = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
         b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
for path in list(macos.rglob('*')):
    if not path.is_file() or path.is_symlink(): continue
    with path.open('rb') as stream: native = stream.read(4) in magic
    if native:
        # The host may canonicalize the managed entry assembly path. Both roots
        # must resolve P/Invoke siblings while the signed native file stays in MacOS.
        if path.name != 'Galaxy Buds Manager':
            alias = payload / path.relative_to(macos)
            alias.parent.mkdir(parents=True, exist_ok=True)
            alias.symlink_to(os.path.relpath(path, alias.parent))
        continue
    destination = payload / path.relative_to(macos)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(path, destination)
    path.symlink_to(os.path.relpath(destination, path.parent))
PYDATA

# Read the existing version; do not change application identity or user config.
python3 - "$ROOT/GalaxyBudsClient/Application.props" "$STAGED/Contents/Info.plist" "$ROOT" "$CONFIGURATION" "$BUDS_RUNTIME_VERSION" "$WORK/managed-inputs.json" <<'PY'
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET

version = ET.parse(sys.argv[1]).findtext('.//Version')
if not version:
    raise SystemExit('Missing application version')
root = Path(sys.argv[3])
native_manifest = json.loads((root / 'macOSAutoSwitch/dist/libBudsNative.build.json').read_text())
if native_manifest.get('configuration') != sys.argv[4]:
    raise SystemExit('Native/managed build configuration mismatch')
for compiled in native_manifest['sources']:
    source = root / 'macOSAutoSwitch' / compiled['path']
    if hashlib.sha256(source.read_bytes()).hexdigest() != compiled['sha256']:
        raise SystemExit('Native source drift after compilation; staged app discarded: ' + compiled['path'])
sources = list((root / 'macOSAutoSwitch/Sources').rglob('*.swift'))
sources += [root / 'macOSAutoSwitch/Tools/AccountSignInProbe.swift',
            root / 'macOSAutoSwitch/Tools/BudsGuardHelperMain.swift',
            root / 'macOSAutoSwitch/scripts/PlaybackObserverMain.swift',
            root / 'macOSAutoSwitch/scripts/build-native-library.sh',
            root / 'scripts/build-buds-macos.sh']
for folder in ['Platform', 'Interface', 'Cli']:
    sources += [p for p in (root / 'GalaxyBudsClient' / folder).rglob('*')
                if p.is_file() and p.suffix in {'.cs', '.axaml'}]
sources += [root / 'GalaxyBudsClient/App.axaml.cs', root / 'GalaxyBudsClient/GalaxyBudsClient.csproj']
sources += [root / 'config/updates.json', root / 'scripts/configure-updates.py', root / 'scripts/fetch-sparkle.sh']
records = [{'path': str(p.relative_to(root)), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
           for p in sorted(set(sources))]
build_id = hashlib.sha256(json.dumps(records, sort_keys=True).encode()).hexdigest()[:16]
excluded_native = {'AutoSwitchModel.swift', 'BudsAutoSwitchApp.swift', 'CommandRunner.swift'}
build = {'build_id': build_id, 'configuration': sys.argv[4],
         'runtime_version': sys.argv[5],
         'managed_build_inputs': json.loads(Path(sys.argv[6]).read_text()),
         'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'sources': records,
         'native_backend': 'bluetooth-only',
         'native_library_configuration': native_manifest['configuration'],
         'native_library_defines': native_manifest['defines'],
         'native_library_excluded_sources': sorted(excluded_native),
         'native_library_sources': ['macOSAutoSwitch/' + item['path'] for item in native_manifest['sources']],
         'native_library_compiled_inputs': native_manifest['sources']}
(Path(sys.argv[2]).parent / 'Resources/BuildInfo.json').write_text(json.dumps(build, indent=2) + '\n')
info = {
    'CFBundleIdentifier': 'me.timschneeberger.galaxybudsclient',
    'CFBundleName': 'Buds',
    'CFBundleDisplayName': 'Buds',
    'CFBundleExecutable': 'Galaxy Buds Manager',
    'CFBundleIconFile': 'Buds.icns',
    'CFBundlePackageType': 'APPL',
    'CFBundleVersion': version,
    'CFBundleShortVersionString': version,
    'BudsBuildIdentifier': build_id,
    'BudsBuildConfiguration': sys.argv[4],
    'NSBluetoothAlwaysUsageDescription': 'Buds uses Bluetooth to connect to and manage your Galaxy Buds.',
    'NSHighResolutionCapable': True,
    'LSMinimumSystemVersion': '14.2',
    'LSUIElement': True,
}
with open(sys.argv[2], 'wb') as stream:
    plistlib.dump(info, stream)
PY
/usr/bin/plutil -lint "$STAGED/Contents/Info.plist"
python3 "$ROOT/scripts/configure-updates.py" "$ROOT/config/updates.json" "$STAGED/Contents/Info.plist"

# Validate native linkage without loading or executing app code, then sign from
# the inside out using the existing identity-selection policy. Capture signer
# output so a failure cannot expose an identity through a Python traceback.
python3 - "$STAGED" "$SIGNER" <<'PY'
from pathlib import Path
import subprocess
import sys
import re

app = Path(sys.argv[1])
macos = app / 'Contents/MacOS'
magic = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
         b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
         b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
binaries = []
for path in app.rglob('*'):
    if path.is_file() and not path.is_symlink():
        with path.open('rb') as stream:
            if stream.read(4) in magic:
                binaries.append(path)

def output(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE)

def rpaths(path):
    lines = output('/usr/bin/otool', '-arch', 'arm64', '-l', str(path)).splitlines()
    return [lines[i + 2].strip().removeprefix('path ').split(' (offset ')[0]
            for i, line in enumerate(lines) if line.strip() == 'cmd LC_RPATH']

def expand(value, owner):
    return value.replace('@loader_path', str(owner.parent)).replace('@executable_path', str(macos))

exe_rpaths = rpaths(macos / 'Galaxy Buds Manager')
for path in binaries:
    subprocess.run(['/usr/bin/lipo', str(path), '-verify_arch', 'arm64'], check=True)
    ids = {line.strip() for line in output('/usr/bin/otool', '-arch', 'arm64', '-D', str(path)).splitlines()[1:]}
    dependencies = output('/usr/bin/otool', '-arch', 'arm64', '-L', str(path)).splitlines()[1:]
    search = [expand(p, path) for p in rpaths(path)]
    search += [expand(p, macos / 'Galaxy Buds Manager') for p in exe_rpaths]
    # .NET resolves P/Invoke siblings directly; dyld dependencies still need
    # their actual load paths to resolve, so do not add an artificial search path.
    for line in dependencies:
        dependency = line.strip().split(' (compatibility version ')[0]
        if dependency in ids or dependency.startswith(('/System/Library/', '/usr/lib/')):
            continue
        if dependency.startswith('@rpath/'):
            candidates = [Path(p) / dependency[len('@rpath/'):] for p in search]
        else:
            candidates = [Path(expand(dependency, path))]
        if not any(p.is_file() and p.resolve().is_relative_to(app.resolve()) for p in candidates):
            raise SystemExit(f'Unresolved bundled dependency: {path.name}: {dependency}')

managed = [] # Managed payload lives under Resources; MacOS holds links only.
targets = sorted((p for p in binaries + managed if p != macos / 'Galaxy Buds Manager'), key=lambda p: len(p.parts), reverse=True)
targets += sorted((p for p in app.rglob('*') if p.is_dir() and not p.is_symlink() and p.suffix in {'.framework', '.xpc', '.app'}),
                  key=lambda p: len(p.parts), reverse=True)
targets.append(app)
for target in targets:
    result = subprocess.run([sys.executable, sys.argv[2], str(target)], capture_output=True)
    if result.returncode:
        detail = result.stderr.decode('utf-8', errors='replace')
        detail = re.sub(r'\b[A-Fa-f0-9]{40}\b', '<identity>', detail)
        detail = re.sub(r'Apple Development:[^\n\"]+', '<developer identity>', detail)
        print(detail[-3000:], file=sys.stderr)
        raise SystemExit(f'Signing/verification failed for {target.relative_to(app.parent)}; identity details suppressed.')
print(f'Signed {len(binaries)} Mach-O files and the bundle using the existing signing policy.')
PY
/usr/bin/codesign --verify --deep --strict "$STAGED"

# Only replace a prior output bearing our ownership marker, after validation.
if [[ -d "$APP" ]]; then
    mv "$APP" "$WORK/previous-Buds.app"
fi
mv "$STAGED" "$APP"
printf 'Built and signed: %s\n' "$APP"
