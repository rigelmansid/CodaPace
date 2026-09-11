//
//  MenuBarIcon.swift — 菜单栏图形绘制
//
//  为什么整块自绘成一张 NSImage,而不是用 SwiftUI 拼 Image + Text:
//  MenuBarExtra 的 label 会把内容按模板图渲染,颜色被抹平成单色 ——
//  而我们需要状态色(正常/橙/红)。自绘 + isTemplate = false 才能保留原色。
//
//  版式:图形 + 两行文字
//    主行 = 数量(剩余百分比)
//    副行 = 速率(正常/偏快),算不出速率时退回显示剩余金额
//

import AppKit

// MARK: - 样式

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case rings   // 双环:外环剩余额度,内环剩余时间
    case bar     // 横条

    var id: String { rawValue }

    func label(_ language: Language) -> String {
        switch self {
        case .rings: return L10n.text(.styleRings, language)
        case .bar:   return L10n.text(.styleBar, language)
        }
    }
}

// MARK: - 状态配色(AppKit 侧)

private extension QuotaStatus {
    /// 正常态用 labelColor —— 跟菜单栏前景色一致,和蓝色的时间环拉开区分;
    /// 只有需要提醒时才上橙/红。
    var nsColor: NSColor {
        switch self {
        case .normal:   return .labelColor
        case .warning:  return .systemOrange
        case .critical: return .systemRed
        }
    }
}

// MARK: - 绘制

enum MenuBarIcon {

    private static let height: CGFloat = 22
    private static let iconSize: CGFloat = 19
    private static let gap: CGFloat = 5
    /// 两行之间压紧一点
    private static let leading: CGFloat = -2

    /// 内层图形取外层的 0.80。
    /// 内环仍比外环细,两圈才不会糊成一团;比例固定下来,改尺寸时也不用重新配。
    /// 双环和横条共用这一个常量。
    private static let innerRatio: CGFloat = 0.80

    // 双环
    private static let outerRingRadius: CGFloat = 7.6
    private static let outerRingWidth: CGFloat = 2.4
    /// 内环略缩,把两环间隙拉回 1.1pt 左右 —— 内环变粗后原来的 4.5 会贴得太近
    private static let innerRingRadius: CGFloat = 4.3

    // 横条
    private static let barHeight: CGFloat = 4
    private static let barSpacing: CGFloat = 2

    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    private static let captionFont = NSFont.systemFont(ofSize: 7.5, weight: .regular)

    // 点开菜单栏时系统会在下面垫一层高亮底,系统的 secondary/tertiaryLabelColor
    // 是为正文排版设计的,压在那层高亮上对比度不够。这里直接从 labelColor
    // 派生固定透明度,保证选中和未选中两种状态下都看得清。
    private static var trackAlpha: CGFloat { 0.30 }
    private static var captionAlpha: CGFloat { 0.78 }

    /// - Parameters:
    ///   - gauge: nil 表示未配置 / 离线 / 加载中,此时只画文字
    ///   - value: 主行文字(剩余百分比)
    ///   - caption: 副行文字。为空时只画一行。
    static func image(gauge: Gauge?,
                      now: Date,
                      style: MenuBarStyle,
                      value: String,
                      caption: String) -> NSImage {

        let status = gauge?.status(now: now) ?? .normal
        let isOverPace = gauge?.pace(now: now).isOverPace ?? false

        // 先只用字体量尺寸(尺寸与颜色无关),颜色留到绘制时再上 ——
        // 动态颜色必须在正确的外观上下文里解析,提前 withAlphaComponent 会把它定死。
        let valueSize = NSAttributedString(string: value, attributes: [.font: valueFont]).size()
        let hasCaption = !caption.isEmpty
        let captionSize = hasCaption
            ? NSAttributedString(string: caption, attributes: [.font: captionFont]).size()
            : .zero

        let textWidth = max(valueSize.width, captionSize.width)
        let iconWidth: CGFloat = gauge == nil ? 0 : iconSize + gap
        let width = ceil(iconWidth + textWidth)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            // 强制按当前有效外观解析动态颜色,否则明暗变体可能取错
            NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
                if let gauge {
                    let box = NSRect(x: 0, y: (height - iconSize) / 2,
                                     width: iconSize, height: iconSize)
                    switch style {
                    case .rings: drawRings(gauge: gauge, now: now, in: box, color: status.nsColor)
                    case .bar:   drawBars(gauge: gauge, now: now, in: box, color: status.nsColor)
                    }
                }

                let valueColor = gauge == nil
                    ? NSColor.labelColor.withAlphaComponent(captionAlpha)
                    : NSColor.labelColor
                let valueText = NSAttributedString(string: value, attributes: [
                    .font: valueFont, .foregroundColor: valueColor,
                ])

                guard hasCaption else {
                    valueText.draw(at: NSPoint(x: iconWidth,
                                               y: (height - valueSize.height) / 2))
                    return
                }

                // 副行常态中性,只在「偏快」时转橙 —— 一直有颜色等于没颜色
                let captionColor = isOverPace
                    ? NSColor.systemOrange
                    : NSColor.labelColor.withAlphaComponent(captionAlpha)
                let captionText = NSAttributedString(string: caption, attributes: [
                    .font: captionFont, .foregroundColor: captionColor,
                ])

                // 两行整体垂直居中(draw(at:) 的锚点是文字左下角)
                let stackHeight = valueSize.height + captionSize.height + leading
                let bottom = (height - stackHeight) / 2

                captionText.draw(at: NSPoint(x: iconWidth, y: bottom))
                valueText.draw(at: NSPoint(x: iconWidth,
                                           y: bottom + captionSize.height + leading))
            }
            return true
        }

        // 保留原色,不让系统当模板图渲染成单色
        image.isTemplate = false
        return image
    }

    // MARK: 双环

    /// 外环 = 剩余额度,内环 = 剩余时间。
    /// 拿不到重置时间就**只画外环** —— 没有的数据不编。
    private static func drawRings(gauge: Gauge, now: Date, in box: NSRect, color: NSColor) {
        let center = NSPoint(x: box.midX, y: box.midY)

        ring(center: center, radius: outerRingRadius, width: outerRingWidth,
             ratio: gauge.remainingRatio, color: color)

        if let window = gauge.window {
            ring(center: center,
                 radius: innerRingRadius,
                 width: outerRingWidth * innerRatio,
                 ratio: window.remainingRatio(now: now),
                 color: .systemBlue)
        }
    }

    private static func ring(center: NSPoint, radius: CGFloat, width: CGFloat,
                             ratio: Double, color: NSColor) {
        // 底圈
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = width
        NSColor.labelColor.withAlphaComponent(trackAlpha).setStroke()
        track.stroke()

        let clamped = max(0, min(1, ratio))
        guard clamped > 0 else { return }

        // 从 12 点方向顺时针走
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: 90, endAngle: 90 - 360 * clamped,
                      clockwise: true)
        arc.lineWidth = width
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

    // MARK: 横条

    /// 上面粗的是剩余额度,下面细的是剩余时间(没有窗口就只有一根)。
    /// 细条同样取粗条的 0.618,和双环用同一个比例。
    private static func drawBars(gauge: Gauge, now: Date, in box: NSRect, color: NSColor) {
        let thin = barHeight * innerRatio

        guard let window = gauge.window else {
            bar(x: box.minX, y: box.midY - barHeight / 2, width: box.width,
                height: barHeight, ratio: gauge.remainingRatio, color: color)
            return
        }

        let stack = barHeight + barSpacing + thin
        let top = box.midY + stack / 2

        bar(x: box.minX, y: top - barHeight, width: box.width,
            height: barHeight, ratio: gauge.remainingRatio, color: color)
        bar(x: box.minX, y: box.midY - stack / 2, width: box.width,
            height: thin, ratio: window.remainingRatio(now: now), color: .systemBlue)
    }

    private static func bar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                            ratio: Double, color: NSColor) {
        let radius = height / 2

        let track = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height),
                                 xRadius: radius, yRadius: radius)
        NSColor.labelColor.withAlphaComponent(trackAlpha).setFill()
        track.fill()

        let filled = max(0, min(1, ratio)) * width
        guard filled > 0 else { return }

        let path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: max(filled, height), height: height),
                                xRadius: radius, yRadius: radius)
        color.setFill()
        path.fill()
    }
}
