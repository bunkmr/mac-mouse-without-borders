// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MWBMacClient",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MWBMacClientCore", targets: ["MWBMacClientCore"]),
        .executable(name: "mwbmac", targets: ["mwbmac"]),
        .executable(name: "MWBMacClientApp", targets: ["MWBMacClientApp"]),
    ],
    targets: [
        // 裸 DEFLATE（libz，windowBits=-15）—— 剪贴板文本协议要求与 .NET DeflateStream 互通。
        .target(name: "CZlibShim",
                path: "Sources/CZlibShim",
                publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("z")]),
        .target(name: "MWBMacClientCore",
                dependencies: ["CZlibShim"],
                path: "Sources/MWBMacClientCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "mwbmac",
                          dependencies: ["MWBMacClientCore"],
                          path: "Sources/mwbmac",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "MWBMacClientApp",
                          dependencies: ["MWBMacClientCore"],
                          path: "Sources/MWBMacClientApp",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
