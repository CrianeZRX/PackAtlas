import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((value >> 16) & 255)/255, green: CGFloat((value >> 8) & 255)/255,
            blue: CGFloat(value & 255)/255, alpha: alpha)
}

func makeIcon(_ size: Int, at url: URL) throws {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: CGFloat(size)/512, y: -CGFloat(size)/512)
    let frame = CGPath(roundedRect: CGRect(x: 32, y: 31, width: 448, height: 449), cornerWidth: 92, cornerHeight: 96, transform: nil)
    context.saveGState()
    context.addPath(frame)
    context.clip()
    context.setFillColor(color(0xf9efd8))
    context.fill(CGRect(x: 30, y: 30, width: 452, height: 452))
    context.setStrokeColor(color(0xa8b7b8, alpha: 0.63))
    context.setLineWidth(1.5)
    for index in stride(from: 42, to: 481, by: 27) {
        let i = CGFloat(index)
        context.move(to: CGPoint(x: 32, y: i)); context.addLine(to: CGPoint(x: 480, y: i))
        context.move(to: CGPoint(x: i, y: 31)); context.addLine(to: CGPoint(x: i, y: 480))
    }
    context.strokePath()
    context.restoreGState()

    let ink = color(0x2e271d)
    func stroke(_ points: [(CGFloat, CGFloat)], fill: CGColor? = nil, border: CGColor? = nil, width: CGFloat = 6) {
        context.beginPath()
        context.move(to: CGPoint(x: points[0].0, y: points[0].1))
        points.dropFirst().forEach { context.addLine(to: CGPoint(x: $0.0, y: $0.1)) }
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setStrokeColor(border ?? ink)
        if let fill {
            context.closePath()
            context.setFillColor(fill)
            context.drawPath(using: .fillStroke)
        } else { context.strokePath() }
    }

    stroke([(128,354),(220,323),(374,349),(310,432),(144,401)], fill: color(0x819b9b, alpha: 0.34), border: color(0x819b9b, alpha: 0.34))
    stroke([(118,210),(236,254),(386,188),(379,327),(234,406),(122,366)], fill: color(0xf0c77a))
    stroke([(236,254),(386,188),(379,327),(234,406)], fill: color(0xd8a74d))
    stroke([(118,210),(253,145),(386,188),(236,254)], fill: color(0xf9df9c))
    stroke([(118,210),(86,165),(218,104),(253,145)], fill: color(0xffecc1))
    stroke([(253,145),(303,100),(432,137),(386,188)], fill: color(0xffecc1))
    stroke([(167,250),(174,362)], width: 5)
    for row in stride(from: 265, to: 361, by: 13) {
        let y = CGFloat(row)
        let x = 168 + (y - 250) * 0.063
        stroke([(x-8,y),(x+8,y+2)], width: 4)
    }
    stroke([(154,242),(177,249),(178,278),(158,274)], fill: color(0xd97255))
    stroke([(232,114),(222,78)], border: color(0xaa392e))
    stroke([(254,108),(259,68)], border: color(0xaa392e))
    stroke([(279,115),(306,88)], border: color(0xaa392e))

    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try makeIcon(size * scale, at: output.appendingPathComponent(name))
    }
}
