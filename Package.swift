// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Perch", targets: ["Perch"]),
        // The ledger reader on its own, so a menu-bar app or CLI can reuse it.
        .library(name: "LedgerKit", targets: ["LedgerKit"]),
    ],
    targets: [
        .target(name: "LedgerKit"),
        .executableTarget(name: "Perch", dependencies: ["LedgerKit"]),
        // `swift run LedgerCheck`: checks for LedgerKit (the Command Line Tools have no XCTest).
        .executableTarget(name: "LedgerCheck", dependencies: ["LedgerKit"]),
    ]
)
