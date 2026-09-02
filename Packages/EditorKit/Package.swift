// swift-tools-version:6.2
//
// EditorKit — in-repo Swift package consolidating the editor stack:
//
//   • EditorEngine — the text-editing view that backs the app (vendored fork
//     of upstream code; see LICENSE files for attribution).
//   • EditorCore subset — utility libraries we use: FileEncoding, LineEnding,
//     LineSort, CharacterInfo, plus transitive deps StringUtils and ValueRange.
//   • PilcrowSyntax — the bridge wiring tree-sitter language grammars into
//     EditorEngine.
//
// The app target depends on this single local package instead of several.

import PackageDescription

let package = Package(
    name: "EditorKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(name: "EditorEngine",  targets: ["EditorEngine"]),
        .library(name: "FileEncoding",  targets: ["FileEncoding"]),
        .library(name: "LineEnding",    targets: ["LineEnding"]),
        .library(name: "LineSort",      targets: ["LineSort"]),
        .library(name: "CharacterInfo", targets: ["CharacterInfo"]),
        .library(name: "PilcrowSyntax",   targets: ["PilcrowSyntax"])
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/tree-sitter", .upToNextMinor(from: "0.20.9")),

        // Tree-sitter language grammars.
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash",        from: "0.25.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c",           from: "0.24.2"),
        .package(url: "https://github.com/1024jp/tree-sitter-css",              branch: "swiftPackage"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go",          from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html",        from: "0.23.2"),
        .package(url: "https://github.com/1024jp/tree-sitter-javascript",       branch: "swiftPackage"),
        .package(url: "https://github.com/1024jp/tree-sitter-python",           branch: "swiftPackage"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-ruby",        from: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust",        from: "0.24.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift",       branch: "with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript",  from: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-java",        from: "0.23.5"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp",         from: "0.23.4"),
        .package(url: "https://github.com/1024jp/tree-sitter-latex",            branch: "swiftPackage"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", from: "0.5.0"),
        .package(name: "TreeSitterTypst", path: "../TreeSitterTypst")
    ],
    targets: [
        // MARK: EditorEngine (vendored text-editing view)

        .target(
            name: "EditorEngine",
            dependencies: [
                .product(name: "TreeSitter", package: "tree-sitter")
            ],
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
                .process("TextView/Appearance/Theme.xcassets")
            ],
            swiftSettings: [
                // This target is vendored code written before Swift 6's strict
                // concurrency. Keep it on Swift 5 semantics so we don't have
                // to retrofit isolation annotations across ~200 files. Other
                // targets in this package use the package-wide tools-version
                // 6.2 mode.
                .swiftLanguageMode(.v5)
            ]
        ),

        // MARK: EditorCore subset (utility targets)

        .target(name: "ValueRange"),

        .target(name: "StringUtils", dependencies: ["ValueRange"]),

        .target(name: "FileEncoding", dependencies: ["ValueRange"]),

        .target(
            name: "LineEnding",
            dependencies: ["StringUtils", "ValueRange"]
        ),

        .target(
            name: "LineSort",
            dependencies: ["StringUtils"]
        ),

        .target(name: "CharacterInfo"),

        // MARK: PilcrowSyntax — tree-sitter ↔ editor bridge

        .target(
            name: "PilcrowSyntax",
            dependencies: [
                "EditorEngine",
                .product(name: "TreeSitter",            package: "tree-sitter"),
                .product(name: "TreeSitterBash",        package: "tree-sitter-bash"),
                .product(name: "TreeSitterC",           package: "tree-sitter-c"),
                .product(name: "TreeSitterCSS",         package: "tree-sitter-css"),
                .product(name: "TreeSitterGo",          package: "tree-sitter-go"),
                .product(name: "TreeSitterHTML",        package: "tree-sitter-html"),
                .product(name: "TreeSitterJavaScript",  package: "tree-sitter-javascript"),
                .product(name: "TreeSitterPython",      package: "tree-sitter-python"),
                .product(name: "TreeSitterRuby",        package: "tree-sitter-ruby"),
                .product(name: "TreeSitterRust",        package: "tree-sitter-rust"),
                .product(name: "TreeSitterSwift",       package: "tree-sitter-swift"),
                .product(name: "TreeSitterTypeScript",  package: "tree-sitter-typescript"),
                .product(name: "TreeSitterJava",        package: "tree-sitter-java"),
                .product(name: "TreeSitterCPP",         package: "tree-sitter-cpp"),
                .product(name: "TreeSitterLatex",       package: "tree-sitter-latex"),
                // The package bundles both block and inline targets under
                // the single `TreeSitterMarkdown` library product.
                .product(name: "TreeSitterMarkdown",    package: "tree-sitter-markdown"),
                .product(name: "TreeSitterTypst",       package: "TreeSitterTypst")
            ],
            resources: [
                .copy("Queries")
            ]
        )
    ]
)
