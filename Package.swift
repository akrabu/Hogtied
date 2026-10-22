// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Hogtied",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Hogtied", targets: ["Hogtied"]),
        .executable(name: "HogtiedHelper", targets: ["HogtiedHelper"])
    ],
    targets: [
        .target(name: "HogCore"),
        .target(name: "HogIPC", dependencies: ["HogCore"]),
        .executableTarget(name: "Hogtied", dependencies: ["HogCore", "HogIPC"]),
        .executableTarget(name: "HogtiedHelper", dependencies: ["HogCore", "HogIPC"]),
        .executableTarget(name: "HogCoreChecks", dependencies: ["HogCore", "HogIPC"], path: "Checks")
    ]
)
