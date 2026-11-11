// swift-tools-version: 6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let runtime = root + "/.build/OpenCVRuntime"
let package = Package(
    name: "Board", platforms: [.macOS("26.0")],
    products: [.executable(name: "Board", targets: ["BoardApp"])],
    targets: [
        .target(name: "BoardNativeTracker", publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-I" + runtime + "/include/opencv4"])],
            linkerSettings: [.unsafeFlags(["-L" + runtime + "/lib", "-Xlinker", "-rpath", "-Xlinker", runtime + "/lib",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedLibrary("opencv_calib3d"), .linkedLibrary("opencv_features2d"), .linkedLibrary("opencv_flann"),
                .linkedLibrary("opencv_imgproc"), .linkedLibrary("opencv_core")]),
        .executableTarget(name: "BoardApp", dependencies: ["BoardNativeTracker"])
    ],
    swiftLanguageModes: [.v5], cxxLanguageStandard: .cxx17
)
