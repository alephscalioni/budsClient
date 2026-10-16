# BudsClient for macOS

Aplicativo independente para Galaxy Buds na barra de menus do macOS.

[Baixar a versão mais recente](https://github.com/alephscalioni/BudsClient/releases/latest)

Reúne Samsung Account, alternância automática, bateria, controles dos fones e
atualização automática do app em um painel nativo. Os controles disponíveis
dependem do modelo e de uma conexão confirmada com o fone. A integração foi
testada fisicamente com Buds3 Pro; Buds4 e outros modelos ainda precisam de
validação. A consulta de firmware está disponível; a instalação de firmware
continua pelo Galaxy Wearable.

O ZIP da release contém `Buds.app`. Esta primeira versão pública usa uma
assinatura de desenvolvimento e ainda não tem notarização da Apple.

## Compilar

The native app uses a pinned GalaxyBudsClient managed host.
Requires Apple Silicon, macOS 14.2+, Xcode, Python 3 and .NET SDK 10.0.300.
See `LICENSE` and `NOTICE` for attribution and corresponding dependency source.

```text
.github/workflows/macos.yml       macOS tests, build and zipped CI artifact
config/updates.json               public version, feed and verification key
dependency.json                   exact upstream commit and archive SHA-256
global.json                       .NET SDK pin
macOSAutoSwitch/
  Package.swift                   library target for isolated Swift tests
  Sources/BudsAutoSwitch/          production Swift, including SwitchPolicy
  Resources/Buds.icns              native application icon
  Tests/BudsAutoSwitchTests/       synthetic protocol/lifecycle/safety tests
  Tools/                          AccountSignInProbe.swift, BudsGuardHelperMain.swift
  scripts/                        native compiler, playback resource and signer
overlays/                         added managed host source, tests and icon
patches/managed-host.patch         only modified original files against the pin
scripts/                          assembly, build wrappers and update/release tools
  internal/                       preserved packager and pinned Sparkle fetcher
tests/test_export.py              assembly provenance and release rejection tests
LICENSE
NOTICE
```

```bash
python3 -m unittest discover -s tests -v
swift test --disable-keychain --disable-netrc --package-path macOSAutoSwitch
python3 scripts/assemble-source.py
bash scripts/build-native-interop.sh
dotnet test .build/workspace/GalaxyBudsClient/GalaxyBudsClient.Tests/GalaxyBudsClient.Tests.csproj -c Release -p:UseMacOSSDK=false -p:PackNative=true --filter 'FullyQualifiedName~NativeBuds'
bash scripts/build-native-library.sh
BUDS_DOTNET="$(command -v dotnet)" bash scripts/build-buds-macos.sh
```

Assembly fetches only the exact official dependency and verifies its archive
hash. The generated macOS workspace is `.build/workspace/GalaxyBudsClient`;
Sparkle 2.10.0 lives at its required sibling path
`.build/workspace/tools/sparkle-2.10.0`. Both are ignored. The app is `dist/Buds.app`.
`BUDS_DOTNET` can also point to a local SDK; no .NET binaries are vendored.
The canonical packager is unchanged except for its output-directory override.
It retains source-hash, running-app, recovery-journal and bundle-ownership checks.

Packaging signs with the existing identity policy. Set
`BUDS_ACCOUNT_SIGNING_IDENTITY=-` for an ad-hoc CI build. Packaging never installs
or launches the app. CI archives are ad-hoc builds, not notarized releases.
`python3 scripts/prepare-release.py` is a separate, deliberate signing operation:
it validates the assembled sources and `dist` build before using the existing
Keychain account `alephscalioni.BudsClient.updates`. It never exports a private key.
Public feed/key settings remain in `config/updates.json`.

This export excludes upstream history/source copies, old workflows and README,
other platforms, Android/ADB experiments, obsolete standalone Swift app sources,
probes except the two embedded tools, screenshots, reports, design artifacts,
SDKs and compiled binaries. Fetched source and build outputs stay ignored.
NativeInterop retains the upstream locked Magnet/Sauce package references;
normal builds need those source dependencies available to Xcode. Offline
validation cannot resolve them if their local source cache is absent.
