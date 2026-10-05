// Draws the SnatchMac app icon and builds Resources/AppIcon.icns.
// Run from the repo root: swift scripts/make_icon.swift
import AppKit

let size: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Apple's macOS icon grid: 824pt body centred on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(squircle); ctx.setFillColor(rgb(0x3D5AFE)); ctx.fillPath()
ctx.restoreGState()

// Gradient body: bright blue at the top to deep indigo at the bottom
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let gradient = CGGradient(colorsSpace: cs, colors: [rgb(0x4FA3FF), rgb(0x4B5BF6), rgb(0x5B2FD9)] as CFArray,
                          locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
// Soft top sheen
let sheen = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY + 60), options: [])
ctx.restoreGState()

// Viewfinder corner brackets
let frame = CGRect(x: 262, y: 262, width: 500, height: 500)
let arm: CGFloat = 132
ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.setLineWidth(46)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
for (corner, dx, dy) in [(CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0),
                         (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0),
                         (CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0),
                         (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0)] {
    ctx.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
    ctx.addLine(to: corner)
    ctx.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
}
ctx.strokePath()

// Lines of text inside: the middle one is the "snatched" line, bright and highlighted
func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ color: CGColor) {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: 44), cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.setFillColor(color); ctx.fillPath()
}
bar(352, 590, 300, rgb(0xFFFFFF, 0.45))
// highlight behind the middle line
ctx.addPath(CGPath(roundedRect: CGRect(x: 328, y: 470, width: 368, height: 84), cornerWidth: 26, cornerHeight: 26, transform: nil))
ctx.setFillColor(rgb(0xFFD54A, 0.95)); ctx.fillPath()
bar(352, 490, 320, rgb(0x2B2A8C))
bar(352, 390, 240, rgb(0xFFFFFF, 0.45))

// Write the 1024 master + iconset + icns
let fm = FileManager.default
let master = URL(fileURLWithPath: "Resources/AppIcon-1024.png")
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: master)

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-z", "\(px)", "\(px)", master.path, "--out", iconset.appendingPathComponent(name).path]
        p.standardOutput = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run(); iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
