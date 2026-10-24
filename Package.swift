// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LangSwitch",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "LangSwitch", targets: ["LangSwitch"]),
    ],
    targets: [
        .target(
            name: "LangSwitchCore",
            path: "Sources/LangSwitchCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "LangSwitch",
            dependencies: ["LangSwitchCore"],
            path: "Sources/CapsLangSwitcher"
        ),
        .testTarget(
            name: "LangSwitchTests",
            dependencies: ["LangSwitchCore"],
            path: "Tests/LangSwitchTests"
        ),
    ]
)
