// swift-tools-version: 6.2
// DialInCamera: writes AI-generated film looks into a Fujifilm X100VI's C1–C7 custom slots.
// Library for the iPhone app (iOS 26+) plus a macOS CLI (`dialin-cam`) for bench tests against the real camera.
import PackageDescription

let package = Package(
    name: "DialInCamera",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DialInCamera", targets: ["DialInCamera"]),
        .executable(name: "dialin-cam", targets: ["dialin-cam"]),
    ],
    targets: [
        .target(name: "DialInCamera"),
        .executableTarget(
            name: "dialin-cam",
            dependencies: ["DialInCamera"],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist in the binary so CoreBluetooth / ImageCaptureCore find their usage strings
                // (an unbundled CLI that touches Bluetooth without one is killed by TCC). macOS only.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Sources/dialin-cam/Info.plist",
                ], .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "DialInCameraTests",
            dependencies: ["DialInCamera"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
