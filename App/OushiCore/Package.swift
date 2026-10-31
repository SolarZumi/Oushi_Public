// swift-tools-version: 6.2
// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import PackageDescription

// The review's logic and storage, apart from the app so it can be tested on the Mac with `swift test` and so the
// views see only the surface it chooses to make public.
let package = Package(
    name: "OushiCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "OushiCore", targets: ["OushiCore"]),
    ],
    targets: [
        .target(name: "OushiCore", swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(name: "OushiCoreTests", dependencies: ["OushiCore"], swiftSettings: [.treatAllWarnings(as: .error)]),
    ]
)
