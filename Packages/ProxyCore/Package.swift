// swift-tools-version:5.9
import PackageDescription

// ProxyCore: builds the sing-box config from the two airport subscriptions, and models the Clash API answers.
// Foundation only, so it builds and tests on Linux too (`swift test`); `proxy-config` is a Linux/macOS CLI that
// runs the same builder for end-to-end tests with a desktop sing-box.
let package = Package(
    name: "ProxyCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "ProxyCore", targets: ["ProxyCore"])],
    targets: [
        .target(name: "ProxyCore"),
        .executableTarget(name: "proxy-config", dependencies: ["ProxyCore"]),
        .testTarget(name: "ProxyCoreTests", dependencies: ["ProxyCore"]),
    ]
)
