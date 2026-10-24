// swift-tools-version: 5.9
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk
//
// Tuist XcodeProj-based SPM integration: declare dependencies here, then reference in
// Project.swift via .external(name: "ProductName"). Run `mise run install` then `mise run generate` to resolve.

import PackageDescription

#if TUIST
    import ProjectDescription

    let packageSettings = PackageSettings(
        productTypes: [:]
    )
#endif

let package = Package(
    name: "Piper",
    dependencies: [
        .package(url: "https://github.com/piper-tts-apps/piper-objc", from: "0.2.49"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: []  // Tuist uses this only to resolve deps; targets are in Project.swift via .external()
)
