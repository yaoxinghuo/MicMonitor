import AppKit

/// 菜单栏图标,用 NSBezierPath 手绘(等比还原用户提供的 18×18 SVG),
/// template 渲染由系统根据菜单栏明暗自动反色,比位图更锐利。
///
/// SVG 坐标系 y 向下,Cocoa y 向上:本文件内所有 y 值已做 y' = 18 − y 翻转。
enum MenuBarIcon {

    // 菜单栏图标视觉尺寸 ~22pt;原 18×18 设计稿有效内容占 ~56% 高度,
    // 放大 1.15× 后视觉占比 ~47%~58%(横向图标,以高度对齐邻居,1.4× 实测过大)
    private static let size = NSSize(width: 22, height: 22)
    private static let artworkScale: CGFloat = 1.15

    /// 未生效:头梁弧线 + 两个描边耳罩(纯线条)
    static var off: NSImage = make { _ in
        // 头梁:以 (9, 8) 为圆心、半径 5.4 的上半圆弧
        let band = NSBezierPath()
        band.appendArc(withCenter: NSPoint(x: 9, y: 8), radius: 5.4,
                       startAngle: 180, endAngle: 0, clockwise: true)
        band.lineWidth = 1.6
        band.lineCapStyle = .round
        band.stroke()

        // 左右描边耳罩(SVG rect y=9.8 h=4.8 → 翻转后 y=3.4)
        for x in [2.5, 13.3] as [CGFloat] {
            let cup = NSBezierPath(roundedRect: NSRect(x: x, y: 3.4, width: 2.2, height: 4.8),
                                   xRadius: 1.1, yRadius: 1.1)
            cup.lineWidth = 1.2
            cup.lineCapStyle = .round
            cup.stroke()
        }
    }

    /// 生效:头梁弧线 + 填充耳罩 + 麦克风圆点及上方两圈声波
    static var on: NSImage = make { _ in
        let band = NSBezierPath()
        band.appendArc(withCenter: NSPoint(x: 9, y: 8), radius: 5.4,
                       startAngle: 180, endAngle: 0, clockwise: true)
        band.lineWidth = 1.6
        band.lineCapStyle = .round
        band.stroke()

        // 左右填充耳罩(SVG rect y=9.2 h=6 → 翻转后 y=2.8)
        for x in [1.9, 12.7] as [CGFloat] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 2.8, width: 3.4, height: 6.0),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }

        // 麦克风圆点(9, 4.8),两圈声波以它为圆心向上张开(约 40°~140°)
        NSBezierPath(ovalIn: NSRect(x: 9 - 1.4, y: 4.8 - 1.4, width: 2.8, height: 2.8)).fill()
        for r in [2.2, 3.8] as [CGFloat] {
            let wave = NSBezierPath()
            wave.appendArc(withCenter: NSPoint(x: 9, y: 4.8), radius: r,
                           startAngle: 140, endAngle: 40, clockwise: true)
            wave.lineWidth = 1.2
            wave.lineCapStyle = .round
            wave.stroke()
        }
    }

    private static func make(_ draw: @escaping (NSRect) -> Void) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.set()
            // 以画布中心为原点放大图形(原坐标按 18×18 设计,这里平移到中心再缩放)
            let t = NSAffineTransform()
            t.translateX(by: size.width / 2, yBy: size.height / 2)
            t.scale(by: artworkScale)
            t.translateX(by: -9, yBy: -9)
            t.concat()
            draw(rect)
            return true
        }
        img.isTemplate = true   // 菜单栏 template:系统按背景自动渲染黑/白
        return img
    }
}
