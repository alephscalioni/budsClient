#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${CONFIGURATION:-Release}"
case "$configuration" in Debug|Release) ;; *) printf 'Invalid native configuration\n' >&2; exit 1 ;; esac
defines=(-D BUDS_EMBEDDED)
optimization=(-O)
if [[ "$configuration" == Debug ]]; then defines+=(-D DEBUG); optimization=(-Onone); fi
bash "$project_dir/../scripts/fetch-sparkle.sh"
sparkle_dir="$project_dir/../../tools/sparkle-2.10.0"
mkdir -p "$project_dir/dist"
work="$(mktemp -d "$project_dir/dist/.native-build.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
# Snapshot the exact inputs. Parallel source work can never silently produce a
# dylib whose manifest describes a later version of the files.
python3 - "$project_dir" "$work" "$configuration" <<'PY'
from pathlib import Path
import hashlib,json,shutil,sys
root=Path(sys.argv[1]);work=Path(sys.argv[2]);excluded={'AutoSwitchModel.swift','BudsAutoSwitchApp.swift','CommandRunner.swift'}
files=[p for p in (root/'Sources/BudsAutoSwitch').glob('*.swift') if p.name not in excluded]+[root/'Tools/AccountSignInProbe.swift']
records=[];snap=work/'Sources';snap.mkdir()
for p in sorted(files):
 data=p.read_bytes();(snap/p.name).write_bytes(data)
 records.append({'path':str(p.relative_to(root)),'sha256':hashlib.sha256(data).hexdigest()})
(work/'inputs.json').write_text(json.dumps({'sources':records,'excluded_sources':sorted(excluded),
 'configuration':sys.argv[3],'defines':['BUDS_EMBEDDED']+(['DEBUG']if sys.argv[3]=='Debug'else[])},indent=2)+'\n')
PY
xcrun swiftc "${optimization[@]}" -emit-library -parse-as-library "${defines[@]}" \
  -F "$sparkle_dir" -framework Sparkle -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -framework AppKit -framework SwiftUI -framework AuthenticationServices -framework Security -framework CoreAudio -framework IOBluetooth -framework CoreBluetooth \
  -Xlinker -install_name -Xlinker @rpath/libBudsNative.dylib \
  "$work"/Sources/*.swift -o "$work/libBudsNative.dylib"
python3 - "$project_dir" "$work/inputs.json" <<'PY'
from pathlib import Path
import hashlib,json,sys
root=Path(sys.argv[1]);record=json.loads(Path(sys.argv[2]).read_text());excluded=set(record['excluded_sources'])
actual={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (root/'Sources/BudsAutoSwitch').glob('*.swift') if p.name not in excluded}
actual['Tools/AccountSignInProbe.swift']=hashlib.sha256((root/'Tools/AccountSignInProbe.swift').read_bytes()).hexdigest()
expected={r['path']:r['sha256']for r in record['sources']}
if actual!=expected:raise SystemExit('Native inputs changed during compilation; previous library preserved. Rebuild after source work settles.')
PY
mv "$work/libBudsNative.dylib" "$project_dir/dist/libBudsNative.dylib"
mv "$work/inputs.json" "$project_dir/dist/libBudsNative.build.json"
printf '%s\n' "$project_dir/dist/libBudsNative.dylib"
