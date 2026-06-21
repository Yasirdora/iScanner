// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ScanEngine",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ScanEngine", targets: ["ScanCore"]),
    ],
    targets: [
        .target(name: "ScanCore"),
    ]
)
