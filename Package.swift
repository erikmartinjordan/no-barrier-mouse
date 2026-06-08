// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "no-barrier-mouse",
    platforms: [.macOS(.v10_15)],
    products: [
        .executable(name: "NoBarrierMouse", targets: ["NoBarrierMouse"])
    ],
    targets: [
        .target(
            name: "NoBarrierMouse",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Network")
            ]
        )
    ]
)
