// Draws the Mewp app icon: a flat white cat head on a blue tile.
// Usage (from the repo root): swift scripts/make-icon.swift
// Writes every size in Sources/App/Assets.xcassets/AppIcon.appiconset plus app-icon.png,
// which the similar-images test also uses as a fixture.
import AppKit

let tileTop = NSColor(red: 0.36, green: 0.62, blue: 1.0, alpha: 1)
let tileBottom = NSColor(red: 0.16, green: 0.40, blue: 0.93, alpha: 1)
let face = NSColor.white
let features = NSColor(red: 0.13, green: 0.30, blue: 0.78, alpha: 1)

/// Drawing happens in 1024-point icon space with the origin at the bottom left.
func drawIcon() {
    // Standard macOS icon grid: an 824pt tile centered in 1024.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                            xRadius: 185, yRadius: 185)
    NSGradient(colors: [tileTop, tileBottom])!.draw(in: tile, angle: -90)

    face.setFill()
    face.setStroke()

    // Ears: triangles with a thick round-joined stroke to soften the corners.
    for side: CGFloat in [-1, 1] {
        let ear = NSBezierPath()
        ear.move(to: NSPoint(x: 512 + side * 222, y: 540))
        ear.line(to: NSPoint(x: 512 + side * 212, y: 752))
        ear.line(to: NSPoint(x: 512 + side * 62, y: 652))
        ear.close()
        ear.lineJoinStyle = .round
        ear.lineWidth = 56
        ear.fill()
        ear.stroke()
    }

    // Head.
    NSBezierPath(ovalIn: NSRect(x: 512 - 290, y: 250, width: 580, height: 440)).fill()

    // Happy closed eyes: upward arcs.
    features.setStroke()
    for side: CGFloat in [-1, 1] {
        let eye = NSBezierPath()
        eye.appendArc(withCenter: NSPoint(x: 512 + side * 112, y: 450), radius: 46,
                      startAngle: 20, endAngle: 160)
        eye.lineWidth = 26
        eye.lineCapStyle = .round
        eye.stroke()
    }

    // Nose.
    features.setFill()
    let nose = NSBezierPath()
    nose.move(to: NSPoint(x: 512 - 26, y: 392))
    nose.line(to: NSPoint(x: 512 + 26, y: 392))
    nose.line(to: NSPoint(x: 512, y: 362))
    nose.close()
    nose.lineJoinStyle = .round
    nose.lineWidth = 12
    features.setStroke()
    nose.fill()
    nose.stroke()
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(px) / 1024)
    scale.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconSet = URL(fileURLWithPath: "Sources/App/Assets.xcassets/AppIcon.appiconset")
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try! render(size).write(to: iconSet.appendingPathComponent("icon_\(size).png"))
}
try! render(1024).write(to: URL(fileURLWithPath: "app-icon.png"))
print("Wrote AppIcon.appiconset and app-icon.png")
