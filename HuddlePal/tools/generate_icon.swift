// Renders the HuddlePal app icon: warm paper field with an
// ink huddle dial, drawn with vector paths (no SF Symbols — Apple's
// symbol license excludes app icons).
//
// Renders into an explicit 1024×1024 *opaque* bitmap: App Store Connect
// rejects icons with an alpha channel, and NSImage.lockFocus would render
// at the display's 2x backing scale. Usage:
//   swift tools/generate_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.png"

guard let cgContext = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue // opaque: no alpha
) else { fatalError("could not create bitmap context") }

let nsContext = NSGraphicsContext(cgContext: cgContext, flipped: false)
NSGraphicsContext.current = nsContext

let paperTop = NSColor(srgbRed: 0.985, green: 0.983, blue: 0.978, alpha: 1)
let paperBottom = NSColor(srgbRed: 0.925, green: 0.922, blue: 0.912, alpha: 1)
let ink = NSColor(srgbRed: 0.102, green: 0.102, blue: 0.094, alpha: 1)
let inkSoft = NSColor(srgbRed: 0.310, green: 0.308, blue: 0.295, alpha: 1)

// Background: vertical paper gradient.
let background = NSGradient(starting: paperTop, ending: paperBottom)!
background.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)

// Faint vignette behind the dial.
let glowColors = [
    ink.withAlphaComponent(0.05).cgColor,
    ink.withAlphaComponent(0.0).cgColor,
] as CFArray
if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0, 1]) {
    cgContext.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: size / 2, y: size / 2), startRadius: 0,
        endCenter: CGPoint(x: size / 2, y: size / 2), endRadius: size * 0.52,
        options: []
    )
}

let center = CGPoint(x: size / 2, y: size / 2)

func strokeCircle(radius: CGFloat, width: CGFloat, color: NSColor) {
    let rect = CGRect(
        x: center.x - radius, y: center.y - radius,
        width: radius * 2, height: radius * 2
    )
    let path = NSBezierPath(ovalIn: rect)
    path.lineWidth = width
    color.setStroke()
    path.stroke()
}

// Huddle door rings.
strokeCircle(radius: size * 0.330, width: size * 0.030, color: inkSoft)
strokeCircle(radius: size * 0.295, width: size * 0.014, color: ink.withAlphaComponent(0.5))

// Dial spokes (5, like a bank-huddle wheel).
let spokeCount = 5
let innerR = size * 0.085
let outerR = size * 0.225
for i in 0..<spokeCount {
    let angle = CGFloat(i) * (2 * .pi / CGFloat(spokeCount)) + .pi / 2
    let path = NSBezierPath()
    path.move(to: NSPoint(
        x: center.x + cos(angle) * innerR,
        y: center.y + sin(angle) * innerR
    ))
    path.line(to: NSPoint(
        x: center.x + cos(angle) * outerR,
        y: center.y + sin(angle) * outerR
    ))
    path.lineWidth = size * 0.034
    path.lineCapStyle = .round
    ink.setStroke()
    path.stroke()

    // Spoke end knob.
    let knobR = size * 0.030
    let knobCenter = CGPoint(
        x: center.x + cos(angle) * outerR,
        y: center.y + sin(angle) * outerR
    )
    ink.setFill()
    NSBezierPath(ovalIn: CGRect(
        x: knobCenter.x - knobR, y: knobCenter.y - knobR,
        width: knobR * 2, height: knobR * 2
    )).fill()
}

// Hub.
ink.setFill()
let hubR = size * 0.062
NSBezierPath(ovalIn: CGRect(
    x: center.x - hubR, y: center.y - hubR,
    width: hubR * 2, height: hubR * 2
)).fill()
paperBottom.setFill()
let hubInnerR = size * 0.026
NSBezierPath(ovalIn: CGRect(
    x: center.x - hubInnerR, y: center.y - hubInnerR,
    width: hubInnerR * 2, height: hubInnerR * 2
)).fill()

NSGraphicsContext.current = nil

guard let cgImage = cgContext.makeImage() else { fatalError("could not make image") }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) (\(png.count) bytes)")
