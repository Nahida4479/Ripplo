// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RipploSignal",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "RipploSignal", targets: ["RipploSignal"])
    ],
    dependencies: [
        .package(url: "https://github.com/signalapp/libsignal", exact: "0.108.5")
    ],
    targets: [
        .binaryTarget(
            name: "LibSignalFfi",
            url: "https://build-artifacts.signal.org/libraries/libsignal-client-ios-build-v0.108.5.xcframework.zip",
            checksum: "0ee12a1946559ba46f5aea8903b2cf5ff7f06f753f860e481031450dc9aa3aad"
        ),
        .target(
            name: "RipploSignal",
            dependencies: [
                .product(name: "LibSignalClient", package: "libsignal"),
                "LibSignalFfi"
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
