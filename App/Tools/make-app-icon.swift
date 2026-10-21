import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments[1]

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ name: String, opaque: Bool, _ draw: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip so y grows downward, like the reference artwork
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    let url = URL(fileURLWithPath: out).appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

func star(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat, fill: CGColor) {
    let path = CGMutablePath()
    for i in 0..<10 {
        let radius = i % 2 == 0 ? r : r * 0.42
        let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
        let p = CGPoint(x: cx + cos(angle) * radius, y: cy + sin(angle) * radius)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(fill)
    ctx.fillPath()
}

// Back: Twilight's navy disc on near-black, as a soft radial gradient (opaque, required)
render("back.png", opaque: true) { ctx in
    ctx.setFillColor(color(0x0F1115))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x2A3346), color(0x232A38), color(0x141821)] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 560, options: [.drawsAfterEndLocation])
}

// Middle: the crescent moon, with a faint glow
render("middle.png", opaque: false) { ctx in
    ctx.setShadow(offset: .zero, blur: 40, color: color(0xA0BFFF, 0.45))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setFillColor(color(0xA0BFFF))
    ctx.fillEllipse(in: CGRect(x: 430 - 260, y: 545 - 260, width: 520, height: 520))
    // Bite out the inner circle to leave a crescent
    ctx.setBlendMode(.clear)
    ctx.fillEllipse(in: CGRect(x: 545 - 262, y: 505 - 262, width: 524, height: 524))
    ctx.endTransparencyLayer()
}

// Front: the stars and the small planet
render("front.png", opaque: false) { ctx in
    ctx.setShadow(offset: .zero, blur: 24, color: color(0xDCE6FF, 0.5))
    star(ctx, cx: 640, cy: 290, r: 42, fill: color(0xA0BFFF))
    ctx.setFillColor(color(0xA0BFFF))
    ctx.fillEllipse(in: CGRect(x: 730 - 52, y: 380 - 52, width: 104, height: 104))
    star(ctx, cx: 775, cy: 510, r: 70, fill: color(0xDCE6FF))
}
