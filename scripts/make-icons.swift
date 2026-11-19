// Draws the app icon: a plain checkbox with a check, black on white.
// Usage: swift scripts/make-icons.swift <repo root>
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func png(size: Int, macStyle: Bool) -> Data {
    let s = CGFloat(size), u = s / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    if macStyle {
        // macOS icon grid: 824 pt rounded square centered in 1024 with a soft shadow.
        let rect = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 30 * u,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.22))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil))
        ctx.setFillColor(white)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    } else {
        ctx.setFillColor(white)
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    }
    let ink = CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
    let side = 340 * u
    let box = CGRect(x: (s - side) / 2, y: (s - side) / 2, width: side, height: side)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(max(1, 30 * u))
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: 60 * u, cornerHeight: 60 * u, transform: nil))
    ctx.strokePath()
    // The check, drawn in the box's own 0…1 space (y up).
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * side, y: box.minY + y * side) }
    ctx.setLineWidth(max(1, 38 * u))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: p(0.26, 0.50))
    ctx.addLine(to: p(0.43, 0.32))
    ctx.addLine(to: p(0.76, 0.70))
    ctx.strokePath()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base, macStyle: true).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2, macStyle: true).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let web = root.appendingPathComponent("web/icons")
try fm.createDirectory(at: web, withIntermediateDirectories: true)
try png(size: 180, macStyle: false).write(to: web.appendingPathComponent("apple-touch-icon.png"))
try png(size: 192, macStyle: false).write(to: web.appendingPathComponent("icon-192.png"))
try png(size: 512, macStyle: false).write(to: web.appendingPathComponent("icon-512.png"))
print("icons written")
