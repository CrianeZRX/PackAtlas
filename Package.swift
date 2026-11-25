// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuickUnzip",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "QuickUnzipWorkbench", targets: ["QuickUnzipWorkbench"]), .executable(name: "QuickUnzip", targets: ["QuickUnzip"]), .executable(name: "ArchiveBench", targets: ["ArchiveBench"]), .executable(name: "qunzip", targets: ["QuickUnzipCLI"])],
    targets: [
        .systemLibrary(name: "CArchive", path: "Sources/CArchive"),
        .target(name: "CZipCodec", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "ArchiveCore", dependencies: ["CArchive", "CZipCodec"]),
        .executableTarget(name: "QuickUnzipWorkbench", dependencies: ["ArchiveCore"]),
        .executableTarget(name: "QuickUnzip", dependencies: ["ArchiveCore"]),
        .executableTarget(name: "ArchiveBench", dependencies: ["ArchiveCore"]),
        .executableTarget(name: "QuickUnzipCLI", dependencies: ["ArchiveCore"]),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"], resources: [.copy("Fixtures")])
    ]
)
