import AppKit

// One arch, one deck. Same silhouette as the Android vector assets.
func bridge() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 22, y: 74)); p.line(to: NSPoint(x: 22, y: 54))
    p.curve(to: NSPoint(x: 78, y: 54), controlPoint1: NSPoint(x: 22, y: 18), controlPoint2: NSPoint(x: 78, y: 18))
    p.line(to: NSPoint(x: 78, y: 74))
    p.lineWidth = 8.5; p.lineCapStyle = .round; p.lineJoinStyle = .round
    return p
}
func drawMark(scale: CGFloat, x: CGFloat, y: CGFloat, color: NSColor) {
    let transform = AffineTransform(m11: scale, m12: 0, m21: 0, m22: -scale, tX: x, tY: y)
    color.setStroke()
    let arch = bridge(); arch.transform(using: transform); arch.lineWidth = 8.5 * scale; arch.stroke()
    let deck = NSBezierPath(); deck.move(to: NSPoint(x: 14, y: 63)); deck.line(to: NSPoint(x: 86, y: 63))
    deck.transform(using: transform); deck.lineWidth = 8.5 * scale; deck.lineCapStyle = .round; deck.stroke()
}
func write(_ image: NSImage, _ output: String) throws {
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
}
let image = NSImage(size: NSSize(width: 1024, height: 1024)); image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 198, yRadius: 198)
NSGradient(colors: [NSColor(srgbRed: 0.25, green: 0.47, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.12, green: 0.32, blue: 0.84, alpha: 1)])!.draw(in: background, angle: -90)
// A phone silhouette stays legible at notification-banner sizes.
NSColor.white.setStroke()
let phone = NSBezierPath(roundedRect: NSRect(x: 320, y: 210, width: 384, height: 604), xRadius: 72, yRadius: 72)
phone.lineWidth = 34; phone.stroke()
let speaker = NSBezierPath(); speaker.move(to: NSPoint(x: 478, y: 760)); speaker.line(to: NSPoint(x: 546, y: 760))
speaker.lineWidth = 16; speaker.lineCapStyle = .round; speaker.stroke()
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: 499, y: 247, width: 26, height: 26)).fill()
drawMark(scale: 3.6, x: 332, y: 672, color: .white)
// Radio waves connect the device visually to Bridge.
for offset: CGFloat in [0, 42] {
    let wave = NSBezierPath()
    wave.move(to: NSPoint(x: 751 + offset, y: 447 - offset / 2))
    wave.curve(to: NSPoint(x: 751 + offset, y: 577 + offset / 2), controlPoint1: NSPoint(x: 799 + offset, y: 480), controlPoint2: NSPoint(x: 799 + offset, y: 544))
    wave.lineWidth = 20; wave.lineCapStyle = .round; wave.stroke()
}
image.unlockFocus(); try write(image, CommandLine.arguments[1])
if CommandLine.arguments.count > 2 {
    let menu = NSImage(size: NSSize(width: 36, height: 36)); menu.lockFocus()
    drawMark(scale: 0.39, x: -1.5, y: 37, color: .black)
    menu.unlockFocus(); try write(menu, CommandLine.arguments[2])
}
