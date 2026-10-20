// Renders the HuddlePals app icon: warm paper field with the hug mark —
// three pals (tangerine, coral, magenta) held together by one ink arm —
// drawn with vector paths (no SF Symbols — Apple's symbol license excludes
// app icons). The launch reveal in Views/RootView.swift (`HugMark`) draws
// the same mark; keep the two geometries in sync.
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

/// Avatar palette solids (AvatarPalette in Support/Theme.swift).
func hex(_ value: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}
let tangerine = hex(0xF76B15)
let coral = hex(0xE5484D)
let magenta = hex(0xD6409F)

// Background: vertical paper gradient.
let background = NSGradient(starting: paperTop, ending: paperBottom)!
background.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)

// Faint vignette behind the mark.
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

// Geometry in unit coordinates, y up. The mark spans x 0.18…0.82 and is
// vertically centered (y 0.275…0.725).

// The arm: a thick round-capped arc cradling the heads from below.
let arm = NSBezierPath()
arm.appendArc(
    withCenter: NSPoint(x: size * 0.5, y: size * 0.603),
    radius: size * 0.285,
    startAngle: 194.4, // 1.08π
    endAngle: 345.6,   // 1.92π, sweeping through the bottom
    clockwise: false
)
arm.lineWidth = size * 0.085
arm.lineCapStyle = .round
ink.setStroke()
arm.stroke()

// The three pals, the middle one a little higher.
let headRadius = size * 0.076
for (x, y, color) in [(0.335, 0.598, tangerine), (0.5, 0.648, coral), (0.665, 0.598, magenta)] {
    color.setFill()
    NSBezierPath(ovalIn: CGRect(
        x: size * x - headRadius, y: size * y - headRadius,
        width: headRadius * 2, height: headRadius * 2
    )).fill()
}

NSGraphicsContext.current = nil

guard let cgImage = cgContext.makeImage() else { fatalError("could not make image") }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) (\(png.count) bytes)")
