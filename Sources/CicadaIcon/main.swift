import AppKit

let orange = NSColor(srgbRed: 0.91, green: 0.33, blue: 0.17, alpha: 1)
let ink = NSColor(srgbRed: 0.082, green: 0.09, blue: 0.11, alpha: 1)

enum CicadaLogo {
    static let orange = rgb(0xE8552B)
    static let ink = rgb(0x15171C)
    static let white = CGColor(gray: 1, alpha: 1)

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    static func gradient(_ stops: [(UInt32, CGFloat)], at locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { rgb($0.0, $0.1) } as CFArray,
                   locations: locations)!
    }
    static func circle(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        c.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    static func wings(_ c: CGContext) {
        c.move(to: CGPoint(x: 21, y: 42)); c.addQuadCurve(to: CGPoint(x: 44, y: 27), control: CGPoint(x: 26, y: 17))
        c.move(to: CGPoint(x: 78, y: 39)); c.addQuadCurve(to: CGPoint(x: 55, y: 25), control: CGPoint(x: 73, y: 14))
    }
    static let eyes: [(CGFloat, CGFloat)] = [(36, 51), (63, 49)]
    static func tilt(_ c: CGContext) {
        c.translateBy(x: 50, y: 70); c.rotate(by: -5 * .pi / 180); c.translateBy(x: -50, y: -70)
    }

    static func drawIcon(_ c: CGContext, unit: CGFloat) {
        c.saveGState()
        c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerWidth: 23, cornerHeight: 23, transform: nil))
        c.clip()
        c.drawLinearGradient(gradient([(0xF57447, 1), (0xDC461C, 1)], at: [0, 1]),
                             start: .zero, end: CGPoint(x: 100, y: 100), options: [])
        c.drawLinearGradient(gradient([(0xFFFFFF, 0.2), (0xFFFFFF, 0)], at: [0, 1]),
                             start: .zero, end: CGPoint(x: 0, y: 50), options: [])
        c.setLineCap(.round)
        c.setStrokeColor(white); c.setLineWidth(5.5); wings(c); c.strokePath()

        let eyeShade = gradient([(0x3A3E48, 1), (0x0E0F12, 1)], at: [0, 1])
        for (x, y) in eyes {
            c.saveGState(); circle(c, x, y, 12.5); c.clip()
            let centre = CGPoint(x: x - 3.75, y: y - 6.25)
            c.drawRadialGradient(eyeShade, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 22.5,
                                 options: [.drawsAfterEndLocation])
            c.restoreGState()
            c.setStrokeColor(white); c.setLineWidth(5); circle(c, x, y, 12.5); c.strokePath()
            c.setFillColor(white); circle(c, x, y, 8.4); c.fillPath()
            c.setFillColor(ink); circle(c, x + 2, y + 2.2, 4.7); c.fillPath()
            c.setFillColor(white); circle(c, x + 3.5, y + 0.6, 1.5); c.fillPath()
        }

        c.saveGState()
        tilt(c)
        let card = CGPath(roundedRect: CGRect(x: 9, y: 60, width: 104, height: 56), cornerWidth: 12, cornerHeight: 12, transform: nil)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: unit), blur: 4 * unit, color: rgb(0x7A1E05, 0.3))
        c.setFillColor(white); c.addPath(card); c.fillPath()
        c.restoreGState()
        c.saveGState(); c.addPath(card); c.clip()
        c.drawLinearGradient(gradient([(0xFFFFFF, 1), (0xF1EEEC, 1)], at: [0, 1]),
                             start: CGPoint(x: 0, y: 60), end: CGPoint(x: 0, y: 116), options: [])
        c.restoreGState()
        c.saveGState(); c.addPath(card); c.setLineWidth(2); c.replacePathWithStrokedPath(); c.clip()
        c.drawLinearGradient(gradient([(0xFFC9B4, 1), (0xFFFFFF, 1), (0xFFE3A8, 1)], at: [0, 0.5, 1]),
                             start: CGPoint(x: 9, y: 0), end: CGPoint(x: 113, y: 0), options: [])
        c.restoreGState()
        c.setLineWidth(5.4)
        c.setStrokeColor(ink); c.move(to: CGPoint(x: 22, y: 75)); c.addLine(to: CGPoint(x: 72, y: 75)); c.strokePath()
        c.setStrokeColor(orange); c.move(to: CGPoint(x: 22, y: 86)); c.addLine(to: CGPoint(x: 49, y: 86)); c.strokePath()
        c.restoreGState()
        c.restoreGState()
    }
}

func render(_ px: Int, dev: Bool, ios: Bool = false) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let body = ios ? NSRect(x: -80 * s, y: -80 * s, width: 1184 * s, height: 1184 * s) : NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = ios ? NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024 * s, height: 1024 * s))
        : NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    if !ios {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 20 * s
        shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.set()
    }
    orange.setFill()
    squircle.fill()
    NSShadow().set()

    let c = NSGraphicsContext.current!.cgContext
    c.saveGState()
    c.translateBy(x: body.minX, y: body.maxY)
    c.scaleBy(x: body.width / 100, y: -body.height / 100)
    CicadaLogo.drawIcon(c, unit: body.width / 100)
    c.restoreGState()

    if dev {
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        ink.setFill()
        let band = ios ? NSRect(x: 0, y: 0, width: 1024 * s, height: 190 * s) : NSRect(x: body.minX, y: body.minY, width: body.width, height: 170 * s)
        band.fill()
        let font = NSFont.systemFont(ofSize: 110 * s, weight: .heavy)
        let text = NSAttributedString(string: "DEV", attributes: [
            .font: font, .foregroundColor: NSColor.white, .kern: 14 * s,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: band.midX - size.width / 2 + 7 * s, y: band.minY + (band.height - size.height) / 2 + 6 * s))
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    if ios, let image = rep.cgImage,
       let opaque = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
        opaque.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
        if let flat = opaque.makeImage() { return NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:])! }
    }
    return rep.representation(using: .png, properties: [:])!
}

let args = Array(CommandLine.arguments.dropFirst())
let dev = args.contains("--dev")
if let i = args.firstIndex(of: "--ios"), i + 1 < args.count {
    try render(1024, dev: dev, ios: true).write(to: URL(fileURLWithPath: args[i + 1]))
    exit(0)
}
let out = URL(fileURLWithPath: args.first { $0 != "--dev" } ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size, dev: dev).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2, dev: dev).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
