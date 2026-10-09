import AppKit

// Render the launcher logo into an explicit bitmap, independent of screen scale.
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 198, yRadius: 198)
NSGradient(colors: [NSColor(srgbRed: 0.25, green: 0.47, blue: 0.98, alpha: 1),
                    NSColor(srgbRed: 0.12, green: 0.32, blue: 0.84, alpha: 1)])!.draw(in: tile, angle: -90)
NSColor.white.setStroke()
let arch = NSBezierPath()
arch.move(to: NSPoint(x: 286, y: 306))
arch.line(to: NSPoint(x: 286, y: 466))
arch.curve(to: NSPoint(x: 738, y: 466), controlPoint1: NSPoint(x: 286, y: 760), controlPoint2: NSPoint(x: 738, y: 760))
arch.line(to: NSPoint(x: 738, y: 306))
arch.lineWidth = 70; arch.lineCapStyle = .round; arch.lineJoinStyle = .round; arch.stroke()
let deck = NSBezierPath()
deck.move(to: NSPoint(x: 222, y: 394)); deck.line(to: NSPoint(x: 802, y: 394))
deck.lineWidth = 70; deck.lineCapStyle = .round; deck.stroke()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
