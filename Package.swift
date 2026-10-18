// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ServeAnalysis",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "ServeAnalysis", targets: ["ServeAnalysis"]),
    ],
    targets: [
        .target(name: "ServeAnalysis"),
        .testTarget(name: "ServeAnalysisTests", dependencies: ["ServeAnalysis"]),
    ]
)
