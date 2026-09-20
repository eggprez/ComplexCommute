// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CommuteKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "CommuteCore", targets: ["CommuteCore"]),
        .library(name: "GTFSKit", targets: ["GTFSKit"]),
        .library(name: "TransitRouting", targets: ["TransitRouting"]),
    ],
    targets: [
        .target(name: "CommuteCore"),
        .testTarget(name: "CommuteCoreTests", dependencies: ["CommuteCore"]),
        .target(name: "GTFSKit", dependencies: ["CommuteCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "GTFSKitTests", dependencies: ["GTFSKit"]),
        .target(name: "TransitRouting", dependencies: ["CommuteCore", "GTFSKit"]),
        .testTarget(name: "TransitRoutingTests", dependencies: ["TransitRouting"]),
    ]
)
