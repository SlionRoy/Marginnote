// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StudyCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "StudyCore", targets: ["StudyCore"])],
    targets: [
        .target(name: "StudyCore"),
        .testTarget(name: "StudyCoreTests", dependencies: ["StudyCore"])
    ]
)
