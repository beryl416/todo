// Draws the app icon: one white dot in the middle of black.
// Usage: swift scripts/make-icons.swift <repo root>
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func png(size: Int, macStyle: Bool) -> Data {
    let s = CGFloat(size), u = s / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    if macStyle {
        // macOS icon grid: 824 pt rounded square centered in 1024 with a soft shadow.
        let rect = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 30 * u,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.3))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil))
        ctx.setFillColor(black)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    } else {
        ctx.setFillColor(black)
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    }
    // Keep the dot at least ~2 px so it survives the 16 px icon.
    let d = max(2, 112 * u)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d))
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
