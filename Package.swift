// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InternetSpeed",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "InternetSpeed",
            path: "Sources"
        )
    ]
)
