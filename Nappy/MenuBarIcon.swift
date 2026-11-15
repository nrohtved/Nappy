import AppKit

/// The menu bar icon: the moon-and-zzz of the app icon, filled while napping is on and outlined while it is off.
/// The Dev build adds a small dot in the corner so the two apps can be told apart in the menu bar.
enum MenuBarIcon {
    static func image(active: Bool) -> NSImage {
        let name = active ? "moon.zzz.fill" : "moon.zzz"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "Nappy")!.withSymbolConfiguration(config)!
        #if PUBLIC
        symbol.isTemplate = true
        return symbol
        #else
        let size = NSSize(width: symbol.size.width + 3, height: symbol.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: size.width - 6, y: 0, width: 6, height: 6)).fill()
            return true
        }
        image.isTemplate = true
        return image
        #endif
    }
}
