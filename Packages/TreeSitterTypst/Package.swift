// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "TreeSitterTypst",
    platforms: [.iOS(.v11)],
    products: [
        .library(name: "TreeSitterTypst", targets: ["TreeSitterTypst"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "TreeSitterTypst",
                path: ".",
                exclude: [
                    "Cargo.toml",
                    "Makefile",
                    "binding.gyp",
                    "bindings/c",
                    "bindings/go",
                    "bindings/node",
                    "bindings/python",
                    "bindings/rust",
                    "grammar.js",
                    "package.json",
                    "pyproject.toml",
                    "setup.py",
                    "test",
                    ".gitignore",
                ],
                sources: [
                    "src/parser.c",
                    "src/scanner.c",
                ],
                resources: [
                    .copy("queries")
                ],
                publicHeadersPath: "bindings/swift",
                cSettings: [.headerSearchPath("src")])
    ],
    cLanguageStandard: .c11
)
