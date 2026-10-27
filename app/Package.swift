// swift-tools-version:6.0
import PackageDescription

// EarmarkCore holds everything that isn't UI (metadata readers, UCS, music
// keys, database) and builds on Linux too, so its tests run anywhere. The
// Earmark app target uses SwiftUI/AppKit/AVFoundation and is macOS-only.
var targets: [Target] = [
    .target(
        name: "EarmarkCore",
        dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
        resources: [.copy("Resources/ucs_v8.2.1.csv"), .copy("Resources/group_words.bin")]
    ),
    .testTarget(name: "EarmarkCoreTests", dependencies: ["EarmarkCore"], resources: [.copy("Fixtures")]),
]
var products: [Product] = [.library(name: "EarmarkCore", targets: ["EarmarkCore"])]
var dependencies: [Package.Dependency] = [.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0")]

#if os(macOS)
// EarmarkML: decoding (AVFoundation) and Core ML models, macOS only.
targets.append(.target(name: "EarmarkML", dependencies: ["EarmarkCore"]))
targets.append(.executableTarget(name: "Earmark", dependencies: ["EarmarkCore", "EarmarkML"]))
products.append(.executable(name: "Earmark", targets: ["Earmark"]))
// Checks the app's CLAP pipeline against Phase 0 (see models/parity_clap.py).
targets.append(.executableTarget(name: "earmark-parity", dependencies: ["EarmarkCore", "EarmarkML"]))
// The MCP server agents start (docs/mcp-plan.md): its tools in a library, so they can be tested.
dependencies.append(.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")))
targets.append(.target(name: "EarmarkMCP", dependencies: ["EarmarkCore", .product(name: "MCP", package: "swift-sdk")]))
targets.append(.executableTarget(name: "earmark-mcp", dependencies: ["EarmarkMCP"]))
targets.append(.testTarget(name: "EarmarkMCPTests", dependencies: ["EarmarkMCP", "EarmarkCore", .product(name: "MCP", package: "swift-sdk")]))
products.append(.executable(name: "earmark-mcp", targets: ["earmark-mcp"]))
#endif

let package = Package(
    name: "Earmark",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
