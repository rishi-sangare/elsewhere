// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SpoofKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SpoofKit", targets: ["SpoofKit"])],
    targets: [
        .target(name: "SpoofKit"),
        .testTarget(name: "SpoofKitTests", dependencies: ["SpoofKit"]),
    ]
)
