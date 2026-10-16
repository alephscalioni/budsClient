// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "BudsAutoSwitch",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BudsAutoSwitch", targets: ["BudsAutoSwitch"])],
    targets: [
        .binaryTarget(name: "Sparkle", url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip",
                      checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"),
        .target(name: "BudsAutoSwitch", dependencies: ["Sparkle"], linkerSettings: [
            .linkedFramework("SwiftUI"), .linkedFramework("CoreAudio"), .linkedFramework("IOBluetooth")
        ]),
        .testTarget(name: "BudsAutoSwitchTests", dependencies: ["BudsAutoSwitch"])
    ],
    swiftLanguageModes: [.v5]
)
