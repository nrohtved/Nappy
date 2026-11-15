#!/usr/bin/env swift
// Draws the Nappy app icon (the moon-and-zzz logo from the menu header on its indigo-to-purple tile) and writes
// two icon sets into Nappy/Assets.xcassets:
//   AppIcon      the Public icon
//   AppIcon-Dev  the same icon with an orange DEV band along the bottom, so the two apps can be told apart
// Usage: swift tools/make-icons.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.first!).deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appendingPathComponent("Nappy/Assets.xcassets")

func render(pixels s: Int, dev: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: s, pixelsHigh: s, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(s) / 1024
    let tile = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)      // macOS icon grid: 824 pt tile in 1024
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * k, yRadius: 185 * k)

    // soft shadow under the tile
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -12 * k)
    shadow.shadowBlurRadius = 24 * k
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // the tile: system indigo to system purple, top-left to bottom-right, like the logo in the menu
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: NSColor(red: 0x58 / 255, green: 0x56 / 255, blue: 0xD6 / 255, alpha: 1),
               ending: NSColor(red: 0xAF / 255, green: 0x52 / 255, blue: 0xDE / 255, alpha: 1))!.draw(in: tile, angle: -45)
    // a light sheen on the upper half
    NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)

    // the moon with its zzz, white and centred
    let config = NSImage.SymbolConfiguration(pointSize: 400 * k, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let target = tile.width * 0.56
        let scale = min(target / symbol.size.width, target / symbol.size.height)
        let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        symbol.draw(in: NSRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2 + (dev ? 34 * k : 0), width: size.width, height: size.height))
    }

    if dev {
        let band = NSRect(x: tile.minX, y: tile.minY, width: tile.width, height: tile.height * 0.19)
        NSColor(red: 1, green: 0.58, blue: 0, alpha: 1).setFill()
        band.fill()
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let text = NSAttributedString(string: "DEV", attributes: [
            .font: NSFont.systemFont(ofSize: band.height * 0.62, weight: .heavy),
            .foregroundColor: NSColor.white, .kern: band.height * 0.08, .paragraphStyle: style])
        let h = text.size().height
        text.draw(in: NSRect(x: band.minX, y: band.midY - h / 2, width: band.width, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (name, dev) in [("AppIcon", false), ("AppIcon-Dev", true)] {
    let dir = catalog.appendingPathComponent("\(name).appiconset")
    try? FileManager.default.removeItem(at: dir)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for pixels in Set(entries.map { $0.points * $0.scale }).sorted() {
        try! render(pixels: pixels, dev: dev).write(to: dir.appendingPathComponent("icon_\(pixels).png"))
    }
    for e in entries {
        images.append(["filename": "icon_\(e.points * e.scale).png", "idiom": "mac", "scale": "\(e.scale)x", "size": "\(e.points)x\(e.points)"])
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("Contents.json"))
    print("wrote \(name)")
}
