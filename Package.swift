// swift-tools-version:5.9
import PackageDescription

// whisper.cpp is consumed as the official prebuilt XCFramework (v1.9.1, Metal enabled,
// universal arm64+x86_64). Recent whisper.cpp versions no longer ship a usable SwiftPM
// source package (the manifest became a pkg-config system library), so the binary
// framework is the supported route. The framework is committed to the repo;
// `build.sh` only downloads the models at build time.
//
// transcribe.cpp (the engine behind Handy, used here for Parakeet) is a universal
// dylib built by vendor/build-transcribe.sh and committed too: no C++ at app build time.
let transcribeLib = "\(Context.packageDirectory)/vendor/transcribe/lib"

let package = Package(
    name: "YellFlow",
    platforms: [.macOS("13.3")], // matches the prebuilt whisper.framework's minimum
    targets: [
        .binaryTarget(
            name: "whisper",
            path: "vendor/whisper.xcframework"
        ),
        .systemLibrary(
            name: "CTranscribe",
            path: "vendor/transcribe/include"
        ),
        .executableTarget(
            name: "YellFlow",
            dependencies: ["whisper", "CTranscribe"],
            path: "Sources/YellFlow",
            // -L to link; the rpath lets the self-test run from .build. The app
            // bundle finds its copy through @executable_path/../Frameworks.
            linkerSettings: [.unsafeFlags(["-L", transcribeLib, "-Xlinker", "-rpath", "-Xlinker", transcribeLib])]
        )
    ]
)
