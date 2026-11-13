// Renders the app icon. Usage:
//   swift scripts/make-icon.swift [variant] [outDir]     variant: cream (default) | warm | glass | composer
// Writes <outDir>/AppIcon.iconset + <outDir>/AppIcon-<variant>.png (default outDir: Resources).
import AppKit

let canvas: CGFloat = 1024
let body = NSRect(x: 100, y: 100, width: 824, height: 824) // macOS icon grid

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Continuous-curvature squircle (superellipse, n = 5), closer to Apple's mask than a rounded rect.
func squircle(_ rect: NSRect, exponent: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 360
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / exponent), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / exponent), s)
        i == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
    }
    path.close()
    return path
}

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func withShadow(_ alpha: CGFloat, blur: CGFloat, dy: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: -dy)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func clipped(_ path: NSBezierPath, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// Base plate with drop shadow, gradient fill, top sheen and hairline rim.
func drawBase(top: NSColor, bottom: NSColor, sheen: CGFloat, rim: NSColor) -> NSBezierPath {
    let base = squircle(body)
    withShadow(0.30, blur: 24, dy: 10) { NSGradient(starting: top, ending: bottom)!.draw(in: base, angle: -90) }
    clipped(base) {
        let gloss = NSGradient(colors: [NSColor.white.withAlphaComponent(sheen), NSColor.white.withAlphaComponent(0)])!
        gloss.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    }
    rim.setStroke()
    let rimPath = squircle(body.insetBy(dx: 1.5, dy: 1.5))
    rimPath.lineWidth = 3
    rimPath.stroke()
    return base
}

func strokePrompt(at origin: NSPoint, scale: CGFloat, ink: NSColor, cursor: NSColor) {
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: origin.x, y: origin.y + 70 * scale))
    chevron.line(to: NSPoint(x: origin.x + 78 * scale, y: origin.y))
    chevron.line(to: NSPoint(x: origin.x, y: origin.y - 70 * scale))
    chevron.lineWidth = 40 * scale
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    ink.setStroke()
    chevron.stroke()
    cursor.setFill()
    rounded(NSRect(x: origin.x + 122 * scale, y: origin.y - 74 * scale, width: 130 * scale, height: 40 * scale),
            20 * scale).fill()
}

// MARK: Variants

/// Warm gradient plate, frosted white chat bubble carrying a terminal prompt.
func drawWarm() {
    let base = drawBase(top: color(0xFF9F6E), bottom: color(0xD9512C), sheen: 0.22, rim: NSColor.white.withAlphaComponent(0.18))
    clipped(base) {
        let glow = NSGradient(colors: [color(0xFFE3C8, 0.55), color(0xFFE3C8, 0)])!
        glow.draw(fromCenter: NSPoint(x: 300, y: 820), radius: 0, toCenter: NSPoint(x: 300, y: 820), radius: 520, options: [])
    }
    let bubbleRect = NSRect(x: 222, y: 318, width: 580, height: 430)
    let bubble = rounded(bubbleRect, 120)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 330, y: 330))
    tail.curve(to: NSPoint(x: 262, y: 236), controlPoint1: NSPoint(x: 322, y: 290), controlPoint2: NSPoint(x: 300, y: 254))
    tail.curve(to: NSPoint(x: 452, y: 330), controlPoint1: NSPoint(x: 350, y: 250), controlPoint2: NSPoint(x: 420, y: 290))
    tail.close()
    bubble.append(tail)
    withShadow(0.28, blur: 40, dy: 20) {
        NSGradient(starting: color(0xFFFFFF), ending: color(0xFFF1E8))!.draw(in: bubble, angle: -90)
    }
    strokePrompt(at: NSPoint(x: 352, y: 533), scale: 1.05, ink: color(0xE0603A), cursor: color(0xE0603A, 0.85))
}

/// Dark glass plate with a stack of session rows, each with a status dot.
func drawGlass() {
    let base = drawBase(top: color(0x3A3846), bottom: color(0x15141B), sheen: 0.10, rim: NSColor.white.withAlphaComponent(0.14))
    clipped(base) {
        let glow = NSGradient(colors: [color(0xF07A4A, 0.42), color(0xF07A4A, 0)])!
        glow.draw(fromCenter: NSPoint(x: 512, y: 570), radius: 0, toCenter: NSPoint(x: 512, y: 570), radius: 470, options: [])
    }
    let rows: [(y: CGFloat, dot: UInt32, width: CGFloat, highlight: Bool)] = [
        (604, 0xFFA25E, 380, true), (450, 0x6FD48A, 300, false), (296, 0x8E8A99, 340, false),
    ]
    for row in rows {
        let rect = NSRect(x: 214, y: row.y, width: 596, height: 124)
        let pill = rounded(rect, 40)
        withShadow(row.highlight ? 0.40 : 0.25, blur: 30, dy: 12) {
            let fill = row.highlight
                ? NSGradient(starting: color(0xFF9B6A), ending: color(0xE2582F))!
                : NSGradient(starting: NSColor.white.withAlphaComponent(0.20), ending: NSColor.white.withAlphaComponent(0.10))!
            fill.draw(in: pill, angle: -90)
        }
        NSColor.white.withAlphaComponent(row.highlight ? 0.35 : 0.16).setStroke()
        pill.lineWidth = 2
        pill.stroke()
        let dotColor = row.highlight ? color(0xFFFFFF) : color(row.dot)
        dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 46, y: rect.midY - 20, width: 40, height: 40)).fill()
        NSColor.white.withAlphaComponent(row.highlight ? 0.95 : 0.55).setFill()
        rounded(NSRect(x: rect.minX + 118, y: rect.midY - 15, width: row.width, height: 30), 15).fill()
    }
}

/// Light, minimal: cream plate, bold orange prompt, a soft stack hint at the bottom.
func drawCream() {
    let base = drawBase(top: color(0xFFFBF5), bottom: color(0xF1E6D8), sheen: 0.5, rim: color(0xD9C6B0, 0.6))
    clipped(base) {
        let warm = NSGradient(colors: [color(0xFFB083, 0.30), color(0xFFB083, 0)])!
        warm.draw(fromCenter: NSPoint(x: 760, y: 260), radius: 0, toCenter: NSPoint(x: 760, y: 260), radius: 520, options: [])
    }
    for (index, alpha) in [0.18, 0.30].enumerated() {
        let inset = CGFloat(2 - index) * 46
        color(0xE0603A, alpha).setFill()
        rounded(NSRect(x: 250 + inset, y: 236 + CGFloat(index) * 38, width: 524 - inset * 2, height: 26), 13).fill()
    }
    withShadow(0.18, blur: 22, dy: 10) {
        strokePrompt(at: NSPoint(x: 300, y: 560), scale: 1.75, ink: color(0xE0603A), cursor: color(0x2B2722))
    }
}

// MARK: Icon Composer layers (full-bleed 1024 canvas; macOS masks + adds glass)

/// Map the 824pt icon-grid body onto the full canvas so variant geometry can be reused.
func fullBleed(_ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    let scale = canvas / body.width
    transform.scale(by: scale)
    transform.translateX(by: -body.minX, yBy: -body.minY)
    transform.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func creamLayer(_ name: String) -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    fullBleed {
        switch name {
        case "prompt":
            strokePrompt(at: NSPoint(x: 288, y: 528), scale: 1.8, ink: color(0xE0603A), cursor: color(0x2B2722))
        default:
            for (index, alpha) in [0.30, 0.45].enumerated() {
                let inset = CGFloat(2 - index) * 46
                color(0xE0603A, alpha).setFill()
                rounded(NSRect(x: 250 + inset, y: 236 + CGFloat(index) * 38, width: 524 - inset * 2, height: 26), 13).fill()
            }
        }
    }
    image.unlockFocus()
    return image
}

/// Writes <outDir>/AppIcon.icon (icon.json + Assets) for actool.
func writeIconComposerBundle(to outDir: URL) throws {
    let bundle = outDir.appendingPathComponent("AppIcon.icon")
    let assets = bundle.appendingPathComponent("Assets")
    try? FileManager.default.removeItem(at: bundle)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    for name in ["prompt"] {
        try writePNG(creamLayer(name), pixels: Int(canvas), to: assets.appendingPathComponent("\(name).png"))
    }
    let json = """
    {
      "fill" : {
        "linear-gradient" : [
          "srgb:1.00000,0.98431,0.96078,1.00000",
          "srgb:0.94510,0.89804,0.84706,1.00000"
        ]
      },
      "groups" : [
        {
          "layers" : [ { "image-name" : "prompt.png", "name" : "prompt" } ],
          "shadow" : { "kind" : "neutral", "opacity" : 0.45 },
          "translucency" : { "enabled" : false, "value" : 0.4 }
        }
      ],
      "supported-platforms" : { "squares" : "shared" }
    }
    """
    try json.write(to: bundle.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
}

// MARK: Output

func render(_ variant: String) -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    switch variant {
    case "glass": drawGlass()
    case "cream": drawCream()
    default: drawWarm()
    }
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

let args = CommandLine.arguments
let variant = args.count > 1 ? args[1] : "cream"
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "Resources")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
if variant == "composer" {
    try writeIconComposerBundle(to: outDir)
    exit(0)
}
let image = render(variant)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try writePNG(image, pixels: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try writePNG(image, pixels: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try writePNG(image, pixels: 1024, to: outDir.appendingPathComponent("AppIcon-\(variant).png"))
