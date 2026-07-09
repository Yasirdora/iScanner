// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ScanEngine",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ScanEngine", targets: ["ScanEngine", "ScanCore", "ScanCapture", "ScanEnhance", "ScanRecognize", "ScanExport", "ScanExtract"]),
        .executable(name: "scanlab", targets: ["scanlab"]),
    ],
    targets: [
        // One call from photo to cleaned page, text and PDF, built on the stages below.
        .target(
            name: "ScanEngine",
            dependencies: ["ScanCore", "ScanCapture", "ScanEnhance", "ScanRecognize", "ScanExport"]
        ),
        .target(name: "ScanCore"),
        .target(name: "ScanCapture", dependencies: ["ScanCore"]),
        .target(name: "ScanEnhance", dependencies: ["ScanCore"]),
        .target(name: "ScanRecognize", dependencies: ["ScanCore"]),
        .target(name: "ScanExport", dependencies: ["ScanCore", "ScanRecognize"]),
        .target(name: "ScanExtract", dependencies: ["ScanCore", "ScanRecognize"]),
        .executableTarget(
            name: "scanlab",
            dependencies: ["ScanCore", "ScanCapture", "ScanEnhance", "ScanRecognize", "ScanExport", "ScanExtract"]
        ),
        .testTarget(
            name: "ScanEngineTests",
            dependencies: ["ScanEngine", "ScanCore", "ScanCapture", "ScanEnhance", "ScanRecognize", "ScanExport", "ScanExtract"]
        ),
    ]
)
