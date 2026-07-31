// swift-tools-version:5.9
import PackageDescription

// Foundation-only pure-logic package: no UIKit, AVFoundation, or Flutter
// imports allowed anywhere under Sources/. That constraint is what lets
// `swift test` run on the CI host with no simulator (~20s), giving a cheap
// canary on the 4-minute flutter-build-ios round trip. See docs/ios.md
// "Native code layout".
let package = Package(
  name: "IptvsPlayerCore",
  platforms: [
    .macOS(.v12),
    .iOS(.v15),
  ],
  products: [
    .library(name: "IptvsPlayerCore", targets: ["IptvsPlayerCore"])
  ],
  targets: [
    .target(name: "IptvsPlayerCore"),
    .testTarget(name: "IptvsPlayerCoreTests", dependencies: ["IptvsPlayerCore"]),
  ]
)
