// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "GroveRuntimeBuilds", platforms: [.macOS(.v14)],
    products: [.executable(name: "grove-php-release", targets: ["GrovePHPRelease"])],
    targets: [.target(name: "GroveCore", path: "Grove/Grove/Core"),
              .executableTarget(name: "GrovePHPRelease", dependencies: ["GroveCore"], path: "Sources/GrovePHPRelease"),
              .testTarget(name: "GroveCoreTests", dependencies: ["GroveCore"], path: "Tests/GroveCoreTests")],
    swiftLanguageModes: [.v5])
