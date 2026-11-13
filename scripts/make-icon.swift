// Renders Resources/AppIcon.icns: stacked session cards with a terminal prompt.
// Usage: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024
let outDir = URL(fileURLWithPath: "Resources/AppIcon.iconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawCard(_ rect: NSRect, rotation: CGFloat, fill: NSGradient, shadowAlpha: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: rect.midX, yBy: rect.midY)
    transform.rotate(byDegrees: rotation)
    transform.translateX(by: -rect.midX, yBy: -rect.midY)
    transform.concat()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(shadowAlpha)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.set()
    let path = roundedRect(rect, 58)
    fill.draw(in: path, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

func render() -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()

    // Squircle base on the macOS icon grid (824pt body, 100pt margin).
    let base = NSRect(x: 100, y: 100, width: 824, height: 824)
    let basePath = roundedRect(base, 186)
    NSGraphicsContext.saveGraphicsState()
    let baseShadow = NSShadow()
    baseShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    baseShadow.shadowBlurRadius = 28
    baseShadow.shadowOffset = NSSize(width: 0, height: -12)
    baseShadow.set()
    NSGradient(starting: color(0x34323C), ending: color(0x141318))!.draw(in: basePath, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Soft warm glow behind the cards.
    NSGraphicsContext.saveGraphicsState()
    basePath.addClip()
    let glow = NSGradient(colors: [color(0xE07A4F, 0.35), color(0xE07A4F, 0)])!
    glow.draw(fromCenter: NSPoint(x: 512, y: 420), radius: 0, toCenter: NSPoint(x: 512, y: 420), radius: 430, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Back cards = other sessions.
    let cardSize = NSSize(width: 560, height: 380)
    func card(_ dy: CGFloat) -> NSRect {
        NSRect(x: 512 - cardSize.width / 2, y: 262 + dy, width: cardSize.width, height: cardSize.height)
    }
    drawCard(card(124).insetBy(dx: 96, dy: 0), rotation: 0,
             fill: NSGradient(starting: color(0x5A5664), ending: color(0x46424F))!, shadowAlpha: 0.25)
    drawCard(card(62).insetBy(dx: 48, dy: 0), rotation: 0,
             fill: NSGradient(starting: color(0x7B7686), ending: color(0x625D6D))!, shadowAlpha: 0.3)

    // Front card = active session, warm terracotta.
    let front = card(0)
    drawCard(front, rotation: 0,
             fill: NSGradient(starting: color(0xF0936A), ending: color(0xD3592F))!, shadowAlpha: 0.45)

    // Prompt glyph: chevron + cursor bar.
    let ink = color(0xFFF6EE)
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: front.minX + 120, y: front.midY + 78))
    chevron.line(to: NSPoint(x: front.minX + 210, y: front.midY))
    chevron.line(to: NSPoint(x: front.minX + 120, y: front.midY - 78))
    chevron.lineWidth = 46
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    ink.setStroke()
    chevron.stroke()

    let cursor = roundedRect(NSRect(x: front.minX + 262, y: front.midY - 84, width: 170, height: 44), 22)
    ink.withAlphaComponent(0.92).setFill()
    cursor.fill()

    // Top edge highlight on the base for depth.
    NSGraphicsContext.saveGraphicsState()
    basePath.addClip()
    let rim = roundedRect(base.insetBy(dx: 2, dy: 2), 184)
    rim.lineWidth = 4
    NSColor.white.withAlphaComponent(0.10).setStroke()
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let image = render()
try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try writePNG(image, pixels: size, to: outDir.appendingPathComponent("icon_\(size)x\(size).png"))
    try writePNG(image, pixels: size * 2, to: outDir.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try writePNG(image, pixels: 1024, to: URL(fileURLWithPath: "Resources/AppIcon-preview.png"))
print("iconset written; run: iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns")
