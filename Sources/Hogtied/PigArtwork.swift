import AppKit

@MainActor
enum PigArtwork {
    static func image(side: CGFloat, template: Bool = false) -> NSImage {
        if !template, let url = Bundle.main.url(forResource: "Hogtied", withExtension: "png"),
           let artwork = NSImage(contentsOf: url) { return artwork }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        if !template {
            let background = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
                                          xRadius: side * 0.23, yRadius: side * 0.23)
            NSColor(calibratedRed: 1, green: 0.91, blue: 0.9, alpha: 1).setFill()
            background.fill()
        }
        let inset = template ? side * 0.14 : side * 0.12
        drawPig(in: NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2), template: template)
        if template {
            NSColor.black.setStroke()
            let frame = NSBezierPath(roundedRect: NSRect(x: side * 0.055, y: side * 0.055,
                width: side * 0.89, height: side * 0.89), xRadius: side * 0.22, yRadius: side * 0.22)
            frame.lineWidth = max(1, side * 0.065); frame.stroke()
            let knot = NSBezierPath()
            knot.move(to: NSPoint(x: side * 0.80, y: side * 0.07))
            knot.line(to: NSPoint(x: side * 0.94, y: side * 0.20))
            knot.lineWidth = max(1, side * 0.065); knot.lineCapStyle = .round; knot.stroke()
        }
        image.unlockFocus()
        image.isTemplate = template
        return image
    }

    private static func drawPig(in rect: NSRect, template: Bool) {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height,
                                      width: w * rect.width, height: h * rect.height)).fill()
        }
        let pink = template ? NSColor.black : NSColor(calibratedRed: 0.96, green: 0.52, blue: 0.59, alpha: 1)
        pink.setFill()
        let leftEar = NSBezierPath()
        leftEar.move(to: point(0.15, 0.60))
        leftEar.curve(to: point(0.12, 0.93), controlPoint1: point(0.09, 0.70), controlPoint2: point(0.08, 0.97))
        leftEar.curve(to: point(0.40, 0.78), controlPoint1: point(0.18, 0.96), controlPoint2: point(0.34, 0.85))
        leftEar.close()
        leftEar.fill()
        let rightEar = NSBezierPath()
        rightEar.move(to: point(0.60, 0.78))
        rightEar.curve(to: point(0.88, 0.93), controlPoint1: point(0.66, 0.85), controlPoint2: point(0.82, 0.96))
        rightEar.curve(to: point(0.85, 0.60), controlPoint1: point(0.92, 0.97), controlPoint2: point(0.91, 0.70))
        rightEar.close()
        rightEar.fill()
        oval(0.08, 0.09, 0.84, 0.74, pink)
        if !template {
            let inner = NSColor(calibratedRed: 0.81, green: 0.32, blue: 0.43, alpha: 1)
            let ear = NSBezierPath()
            ear.move(to: point(0.19, 0.70)); ear.line(to: point(0.17, 0.84)); ear.line(to: point(0.31, 0.76)); ear.close()
            inner.setFill(); ear.fill()
            let other = NSBezierPath()
            other.move(to: point(0.81, 0.70)); other.line(to: point(0.83, 0.84)); other.line(to: point(0.69, 0.76)); other.close(); other.fill()
            oval(0.25, 0.23, 0.50, 0.30, NSColor(calibratedRed: 1, green: 0.72, blue: 0.74, alpha: 1))
        }
        let ink = NSColor(calibratedRed: 0.36, green: 0.15, blue: 0.22, alpha: 1)
        if template { NSGraphicsContext.current?.compositingOperation = .destinationOut }
        oval(0.29, 0.55, 0.075, 0.085, template ? .black : ink)
        oval(0.635, 0.55, 0.075, 0.085, template ? .black : ink)
        oval(0.36, 0.33, 0.075, 0.11, template ? .black : ink)
        oval(0.565, 0.33, 0.075, 0.11, template ? .black : ink)
        if template { NSGraphicsContext.current?.compositingOperation = .sourceOver }
    }
}
