// swift-tools-version:5.9
import PackageDescription

// whisper.cpp is consumed as the official prebuilt XCFramework (v1.9.1, Metal enabled,
// universal arm64+x86_64). Recent whisper.cpp versions no longer ship a usable SwiftPM
// source package (the manifest became a pkg-config system library), so the binary
// framework is the supported route. The framework is committed to the repo;
// `build.sh` only downloads the whisper model (ggml-large-v3-turbo-q5_0) at build time.
let package = Package(
    name: "YellFlow",
    platforms: [.macOS("13.3")], // matches the prebuilt whisper.framework's minimum
    targets: [
        .binaryTarget(
            name: "whisper",
            path: "vendor/whisper.xcframework"
        ),
        .executableTarget(
            name: "YellFlow",
            dependencies: ["whisper"],
            path: "Sources/YellFlow"
        )
    ]
)
