import AppKit
import Foundation

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
let rect = NSRect(x: 66, y: 66, width: 892, height: 892)
let background = NSBezierPath(roundedRect: rect, xRadius: 198, yRadius: 198)
NSColor(calibratedRed: 0.10, green: 0.43, blue: 0.35, alpha: 1).setFill()
background.fill()
let highlight = NSGradient(starting: NSColor.white.withAlphaComponent(0.16), ending: NSColor.clear)!
highlight.draw(in: background, angle: -70)
let symbol = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)!
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .light).applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let white = symbol.withSymbolConfiguration(config)!
white.isTemplate = false
let symbolRect = NSRect(x: 254, y: 285, width: 516, height: 470)
white.draw(in: symbolRect)
let badgeRect = NSRect(x: 650, y: 190, width: 180, height: 180)
NSColor(calibratedRed: 0.85, green: 0.94, blue: 0.80, alpha: 1).setFill()
NSBezierPath(ovalIn: badgeRect).fill()
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 740, y: 324)); arrow.line(to: NSPoint(x: 740, y: 237))
arrow.move(to: NSPoint(x: 707, y: 268)); arrow.line(to: NSPoint(x: 740, y: 235)); arrow.line(to: NSPoint(x: 773, y: 268))
arrow.lineWidth = 12; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.28, alpha: 1).setStroke(); arrow.stroke()
image.unlockFocus()
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(destination)/icon_\(size)x\(size)\(suffix).png"))
    }
}
