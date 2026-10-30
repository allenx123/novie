// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "NovieMCP",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "NovieMCP", path: "src"),
    ],
    swiftLanguageModes: [.v5]  // matches build.sh's plain swiftc
)
