// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CommuteKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "CommuteCore", targets: ["CommuteCore"]),
    ],
    targets: [
        .target(name: "CommuteCore"),
        .testTarget(name: "CommuteCoreTests", dependencies: ["CommuteCore"]),
    ]
)
