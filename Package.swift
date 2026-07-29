// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FinderAlternative",
    platforms: [.macOS(.v14)],
    products: [
        // The executable is named "Finder++" (the app's actual display
        // name — shown in the Dock/menu bar for this unbundled binary)
        // while the underlying Swift module/target stays "FinderAlternative"
        // — "+" isn't a valid Swift identifier, so the module itself can't
        // be named to match.
        .executable(name: "Finder++", targets: ["FinderAlternative"])
    ],
    dependencies: [
        // First (and, as of this writing, only) third-party dependency —
        // see CLAUDE.md for why this is a deliberate exception to this
        // project's usual "no third-party dependencies" stance: there's no
        // `unrar`/`unar` binary bundled with stock macOS the way there's
        // `unzip`/`tar`, so extracting .rar archives isn't possible without
        // vendoring a library. Wraps RARLAB's own free (extraction-only)
        // UnRAR source under the hood.
        .package(url: "https://github.com/mtgto/Unrar.swift", from: "0.5.4")
    ],
    targets: [
        .executableTarget(
            name: "FinderAlternative",
            dependencies: [
                .product(name: "Unrar", package: "Unrar.swift")
            ],
            path: "Sources/FinderAlternative",
            resources: [.copy("Resources/icon.png")]
        ),
        .testTarget(
            name: "FinderAlternativeTests",
            dependencies: ["FinderAlternative"],
            path: "Tests/FinderAlternativeTests"
        )
    ]
)
