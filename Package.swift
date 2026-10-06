// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "chord",
    platforms: [.macOS(.v13)],
    targets: [
        // 包名全小写，target 名首字母大写，产物二进制就叫 Chord。
        .executableTarget(
            name: "Chord",
            path: "Sources/Chord"
        )
    ]
)
