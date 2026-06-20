import AppKit

/// Draws the Claude "burst" mark as a template image for the menu bar.
/// Template images are auto-tinted by macOS so the icon adapts to light/dark
/// menu bars. The mark is a radial sunburst of evenly spaced tapered rays,
/// evoking Claude's sparkle logo.
enum StatusBarIcon {
    static func image(pointSize: CGFloat = 18) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let rayCount = 12
            let innerRadius = rect.width * 0.12
            let outerRadius = rect.width * 0.46
            let baseHalfWidth = rect.width * 0.052  // half-thickness of each ray at its base

            NSColor.black.setFill()

            for i in 0..<rayCount {
                let angle = (CGFloat(i) / CGFloat(rayCount)) * 2 * .pi - .pi / 2
                let normal = angle + .pi / 2  // perpendicular, for the ray's base width

                let tip = CGPoint(x: center.x + cos(angle) * outerRadius,
                                  y: center.y + sin(angle) * outerRadius)
                let baseCenter = CGPoint(x: center.x + cos(angle) * innerRadius,
                                         y: center.y + sin(angle) * innerRadius)
                let baseLeft = CGPoint(x: baseCenter.x + cos(normal) * baseHalfWidth,
                                       y: baseCenter.y + sin(normal) * baseHalfWidth)
                let baseRight = CGPoint(x: baseCenter.x - cos(normal) * baseHalfWidth,
                                        y: baseCenter.y - sin(normal) * baseHalfWidth)

                let ray = NSBezierPath()
                ray.move(to: baseLeft)
                ray.line(to: tip)
                ray.line(to: baseRight)
                ray.close()
                ray.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
