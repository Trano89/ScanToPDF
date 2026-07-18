// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScanToPDF",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScanToPDF",
            path: "Sources/ScanToPDF"
        )
    ]
)
