// Renders the app icon (a spectrogram with a painted cut through it) at every macOS size.
// Usage: swift scripts/make_icon.swift "Spectrogram Studio/Resources/Assets.xcassets/AppIcon.appiconset"
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func magma(_ t: CGFloat) -> NSColor {
    // Five-stop approximation of the magma colour map.
    let stops: [(CGFloat, CGFloat, CGFloat)] = [(0.0, 0.0, 0.02), (0.23, 0.06, 0.44), (0.55, 0.16, 0.51), (0.94, 0.38, 0.36), (0.99, 0.99, 0.75)]
    let x = max(0, min(0.9999, t)) * CGFloat(stops.count - 1)
    let i = Int(x), f = x - CGFloat(i)
    let a = stops[i], b = stops[i + 1]
    return NSColor(srgbRed: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f, alpha: 1)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1, rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    magma(0.02).setFill(); bg.fill()
    bg.addClip()
    // Harmonic stack rising like a sung note: bright bands, fading with height.
    let cols = 28, rows = 28
    let cw = rect.width / CGFloat(cols), rh = rect.height / CGFloat(rows)
    for c in 0..<cols {
        let u = CGFloat(c) / CGFloat(cols - 1)
        let f0 = 0.12 + 0.06 * sin(u * 2 * .pi)          // fundamental, as a fraction of height
        for r in 0..<rows {
            let v = (CGFloat(r) + 0.5) / CGFloat(rows)
            var level: CGFloat = 0.08
            for h in 1...6 {
                let d = abs(v - f0 * CGFloat(h)) / 0.022
                level = max(level, exp(-d * d) * (1.0 - 0.13 * CGFloat(h)))
            }
            magma(level).setFill()
            NSRect(x: rect.minX + CGFloat(c) * cw, y: rect.minY + CGFloat(r) * rh, width: cw + 0.5, height: rh + 0.5).fill()
        }
    }
    // A painted cut: a soft translucent blue stroke across the upper harmonics.
    let stroke = NSBezierPath()
    stroke.move(to: NSPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.62))
    stroke.curve(to: NSPoint(x: rect.maxX - rect.width * 0.12, y: rect.minY + rect.height * 0.70),
                 controlPoint1: NSPoint(x: rect.midX - rect.width * 0.1, y: rect.minY + rect.height * 0.8),
                 controlPoint2: NSPoint(x: rect.midX + rect.width * 0.1, y: rect.minY + rect.height * 0.52))
    stroke.lineWidth = s * 0.13; stroke.lineCapStyle = .round
    NSColor(srgbRed: 0.25, green: 0.65, blue: 1, alpha: 0.55).setStroke(); stroke.stroke()
    stroke.lineWidth = s * 0.018
    NSColor(srgbRed: 0.75, green: 0.9, blue: 1, alpha: 0.9).setStroke(); stroke.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(base * scale).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["version": 1, "author": "xcode"]],
                                       options: [.prettyPrinted, .sortedKeys])
try! json.write(to: out.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images")
