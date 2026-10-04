// swift-tools-version: 5.9
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "AtlasCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AtlasCore", targets: ["AtlasCore"])],
    targets: [
        .target(name: "ZIMBridge", path: "Native/ZIMBridge", publicHeadersPath: "include",
                cxxSettings: [.unsafeFlags(["-I", root + "/Vendor/libzim/include"])],
                linkerSettings: [.unsafeFlags(["-L", root + "/Vendor/libzim/lib"]), .linkedLibrary("zim"), .linkedLibrary("c++")]),
        .target(name: "AtlasCore", dependencies: ["ZIMBridge"], path: "AtlasCore"),
        .testTarget(name: "AtlasCoreTests", dependencies: ["AtlasCore"], path: "Tests/AtlasCoreTests",
                    linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", root + "/Vendor/libzim/lib"])])
    ],
    cxxLanguageStandard: .cxx17
)
