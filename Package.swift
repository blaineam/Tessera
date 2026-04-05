// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tessera",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "Tessera",
            targets: ["Tessera"]
        )
    ],
    targets: [
        .target(
            name: "Tessera",
            path: "Sources/Tessera"
        ),
        .testTarget(
            name: "TesseraTests",
            dependencies: ["Tessera"],
            path: "Tests/TesseraTests"
        )
    ]
)
