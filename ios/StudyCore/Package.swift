// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StudyCore",
    platforms: [.iOS("18.0"), .macOS(.v14)],
    products: [.library(name: "StudyCore", targets: ["StudyCore"])],
    targets: [
        .target(name: "StudyCore"),
        .testTarget(name: "StudyCoreTests", dependencies: ["StudyCore"])
    ]
)

