// Regenerates app/AppIcon.icns from the "App icon" variant in the Murmur logo sheet.
// Run from the repo root: swift app/tools/make_icon.swift
import AppKit

// The sheet's 96-unit icon: body at 1…95 (rx 21, 1.5 ink stroke), bars rising and falling like a voice.
let bars: [CGRect] = [
    CGRect(x: 19, y: 36, width: 8, height: 24), CGRect(x: 32, y: 20, width: 8, height: 56),
    CGRect(x: 45, y: 32, width: 8, height: 32), CGRect(x: 58, y: 25, width: 8, height: 46),
    CGRect(x: 71, y: 37, width: 6, height: 22),
]
let accent = NSColor(srgbRed: 0x59 / 255, green: 0x95 / 255, blue: 0xC9 / 255, alpha: 1)
let ink = NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255, alpha: 1)

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    // macOS grid: an 824 body centred on a 1024 canvas; flip to the sheet's y-down units.
    let unit = CGFloat(pixels) / 1024 * 824 / 94
    cg.translateBy(x: 0, y: CGFloat(pixels)); cg.scaleBy(x: 1, y: -1)
    cg.translateBy(x: CGFloat(pixels) / 1024 * 100 - unit, y: CGFloat(pixels) / 1024 * 100 - unit)
    cg.scaleBy(x: unit, y: unit)
    let body = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 1.75, width: 92.5, height: 92.5), xRadius: 20.25, yRadius: 20.25)
    accent.setFill(); body.fill()
    ink.setStroke(); body.lineWidth = 1.5; body.stroke()
    ink.setFill(); bars.forEach { NSBezierPath(rect: $0).fill() }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try png(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "app/AppIcon.icns"]
try iconutil.run(); iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
print("app/AppIcon.icns")
