import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

for pointSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = pointSize * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let scaleTransform = NSAffineTransform()
        scaleTransform.scale(by: CGFloat(pixels) / 1024)
        scaleTransform.concat()

        let tile = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(srgbRed: 0.14, green: 0.37, blue: 0.46, alpha: 1),
                   ending: NSColor(srgbRed: 0.22, green: 0.64, blue: 0.57, alpha: 1))?.draw(in: tile, angle: 75)

        NSColor(srgbRed: 0.89, green: 0.99, blue: 0.96, alpha: 1).setFill()
        let layers = [(263.0, 314.0, 498.0), (263, 461, 413), (263, 608, 324)]
        for (x, y, width) in layers {
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: 78), xRadius: 36, yRadius: 36).fill()
        }
        let shine = NSBezierPath()
        shine.move(to: NSPoint(x: 735, y: 728))
        shine.curve(to: NSPoint(x: 843, y: 620), controlPoint1: NSPoint(x: 753, y: 648), controlPoint2: NSPoint(x: 771, y: 638))
        shine.curve(to: NSPoint(x: 735, y: 512), controlPoint1: NSPoint(x: 771, y: 602), controlPoint2: NSPoint(x: 753, y: 592))
        shine.curve(to: NSPoint(x: 627, y: 620), controlPoint1: NSPoint(x: 717, y: 592), controlPoint2: NSPoint(x: 699, y: 602))
        shine.curve(to: NSPoint(x: 735, y: 728), controlPoint1: NSPoint(x: 699, y: 638), controlPoint2: NSPoint(x: 717, y: 648))
        shine.fill()

        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 1 ? "" : "@2x"
        let file = root.appendingPathComponent("icon_\(pointSize)x\(pointSize)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
    }
}
