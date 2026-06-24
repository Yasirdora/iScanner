// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ScanEngine",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ScanEngine", targets: ["ScanCore", "ScanCapture", "ScanEnhance", "ScanRecognize", "ScanExport"]),
    ],
    targets: [
        .target(name: "ScanCore"),
        .target(name: "ScanCapture", dependencies: ["ScanCore"]),
        .target(name: "ScanEnhance", dependencies: ["ScanCore"]),
        .target(name: "ScanRecognize", dependencies: ["ScanCore"]),
        .target(name: "ScanExport", dependencies: ["ScanCore", "ScanRecognize"]),
    ]
)
