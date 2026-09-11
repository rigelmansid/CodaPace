// swift-tools-version:5.9
//
//  只把纯逻辑层 Sources/Core 暴露给 SwiftPM,好处是能脱离 AppKit / SwiftUI 单独跑测试。
//  app 本体由 build.sh 用 swiftc 编译(Core + App 两个目录一起),两边共用同一份源码。
//
//  测试:`swift run CoreTests`
//  本机是 Command Line Tools 环境,不含 XCTest.framework(它只随 Xcode.app 分发),
//  所以测试目标暂时是可执行程序而非 .testTarget。
//  详见 Tests/CoreTests/TestSupport.swift 顶部的迁移说明。
//

import PackageDescription

let package = Package(
    name: "CodaPaceCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CodaPaceCore", targets: ["CodaPaceCore"]),
        .executable(name: "CoreTests", targets: ["CoreTests"]),
    ],
    targets: [
        .target(
            name: "CodaPaceCore",
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "CoreTests",
            dependencies: ["CodaPaceCore"],
            path: "Tests/CoreTests"
        ),
    ]
)
