// 生成 Undertone 的应用图标：靛蓝到青色的渐变圆角方块，中间一个白色的引号气泡。
// swiftc scripts/icon/make_icon.swift -o /tmp/make_icon && /tmp/make_icon scripts/icon/AppIcon.iconset && iconutil -c icns scripts/icon/AppIcon.iconset -o scripts/icon/AppIcon.icns
import AppKit

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS 图标的标准留白：内容约占 80%
    let inset = s * 0.1, rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    ctx.addPath(path); ctx.clip()
    let colors = [CGColor(red: 0.33, green: 0.36, blue: 0.93, alpha: 1), CGColor(red: 0.16, green: 0.70, blue: 0.72, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.5, weight: .semibold).applying(.init(paletteColors: [NSColor(red: 0.30, green: 0.40, blue: 0.90, alpha: 1), .white]))
    if let symbol = NSImage(systemSymbolName: "quote.bubble.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let w = symbol.size.width, h = symbol.size.height
        symbol.draw(in: CGRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: dir.appending(path: "icon_\(base)x\(base).png"))
    try render(base * 2).write(to: dir.appending(path: "icon_\(base)x\(base)@2x.png"))
}
print("ok")
