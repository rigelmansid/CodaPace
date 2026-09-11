//
//  make-icon.swift — 生成应用图标
//
//  用法:swift Scripts/make-icon.swift
//  产物:Resources/AppIcon.icns
//
//  图形就是菜单栏那两个环的放大版:外环剩余额度、内环剩余时间、内环线宽取外环的 80%
//  —— 和 app 里用的是同一套比例。程序坞里看到的和菜单栏里看到的是同一个东西。
//
//  用 CoreGraphics 而不是 AppKit:不需要窗口服务,纯离屏渲染,在任何环境下跑都一样。
//  所有几何量都用画布边长的比例表示,所以 16pt 到 1024pt 是同一份逻辑渲染出来的,
//  不是把一张大图缩小 —— 小尺寸下不会糊。
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 配色

private func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

private let backgroundTop = rgb(0.976, 0.961, 0.933)     // 米白
private let backgroundBottom = rgb(0.949, 0.929, 0.894)
private let trackColor = rgb(0.847, 0.831, 0.788)        // 环的底圈
private let slashColor = rgb(0.831, 0.812, 0.769)        // 比底圈再深一点,才不糊进背景
private let quotaColor = rgb(0.949, 0.451, 0.220)        // 外环:额度
private let timeColor = rgb(0.263, 0.576, 0.898)         // 内环:时间

// MARK: - 几何(全部是画布边长的比例)

private let squircleInset = 0.088
private let cornerRatio = 0.235            // 相对底板边长

private let outerRadius = 0.255
private let outerWidth = 0.070
private let innerRadius = 0.163
private let innerRatio = 0.80              // 内环线宽 / 外环线宽,和 app 一致

private let slashHalfLength = 0.090
private let slashWidth = 0.042
private let slashAngle = 60.0              // 比 45° 陡,更接近字体里的 /

/// 画多少弧。这是展示用的示意值,不代表真实用量。
private let outerArcRatio = 0.72
private let innerArcRatio = 0.45

// MARK: - 绘制

private func makeIcon(side: Int) -> CGImage? {
    let s = CGFloat(side)

    guard let context = CGContext(
        data: nil, width: side, height: side,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // ── 圆角底 ────────────────────────────────────────
    let inset = s * squircleInset
    let box = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = box.width * cornerRatio
    let squircle = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius,
                          transform: nil)

    // 底部一点点投影,让图标从浅色背景上浮起来
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.008),
                      blur: s * 0.022,
                      color: rgb(0, 0, 0, 0.16))
    context.addPath(squircle)
    context.setFillColor(backgroundTop)
    context.fillPath()
    context.restoreGState()

    // 极淡的竖向渐变,避免整块纯色显得平
    context.saveGState()
    context.addPath(squircle)
    context.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [backgroundTop, backgroundBottom] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: box.maxY),
                                   end: CGPoint(x: 0, y: box.minY),
                                   options: [])
    }
    context.restoreGState()

    // ── 双环 ──────────────────────────────────────────
    let center = CGPoint(x: box.midX, y: box.midY)

    func arc(radius: CGFloat, width: CGFloat, ratio: Double, color: CGColor) {
        context.setLineWidth(width)

        // 底圈画满一整圈,和菜单栏一样 —— 让人看得出"总共有多少"
        context.setLineCap(.butt)
        context.setStrokeColor(trackColor)
        context.addArc(center: center, radius: radius,
                       startAngle: 0, endAngle: .pi * 2, clockwise: false)
        context.strokePath()

        guard ratio > 0 else { return }

        // 从 12 点方向顺时针走,圆头端点
        context.setLineCap(.round)
        context.setStrokeColor(color)
        context.addArc(center: center, radius: radius,
                       startAngle: .pi / 2,
                       endAngle: .pi / 2 - .pi * 2 * ratio,
                       clockwise: true)
        context.strokePath()
    }

    arc(radius: s * outerRadius, width: s * outerWidth,
        ratio: outerArcRatio, color: quotaColor)
    arc(radius: s * innerRadius, width: s * outerWidth * innerRatio,
        ratio: innerArcRatio, color: timeColor)

    // ── 中心斜杠 ──────────────────────────────────────
    // 单笔画比文字耐缩,所以各个尺寸都画
    let angle = slashAngle * .pi / 180
    let dx = cos(angle) * s * slashHalfLength
    let dy = sin(angle) * s * slashHalfLength

    context.setLineWidth(s * slashWidth)
    context.setLineCap(.round)
    context.setStrokeColor(slashColor)
    context.move(to: CGPoint(x: center.x - dx, y: center.y - dy))
    context.addLine(to: CGPoint(x: center.x + dx, y: center.y + dy))
    context.strokePath()

    return context.makeImage()
}

// MARK: - 落盘

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "make-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法创建 PNG:\(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "PNG 写入失败:\(url.path)"])
    }
}

// MARK: - 主流程

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)
let output = root.appendingPathComponent("Resources/AppIcon.icns")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)

// iconutil 要求的固定命名
let variants: [(name: String, side: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = makeIcon(side: variant.side) else {
        print("✗ 渲染失败:\(variant.name)")
        exit(1)
    }
    try writePNG(image, to: iconset.appendingPathComponent("\(variant.name).png"))
}
print("▸ 已渲染 \(variants.count) 个尺寸")

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    print("✗ iconutil 失败,退出码 \(iconutil.terminationStatus)")
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
print("✅ 图标已生成:\(output.path)")
