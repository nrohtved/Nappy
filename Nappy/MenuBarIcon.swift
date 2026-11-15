import AppKit

/// The menu bar icon: the moon-and-zzz of the app icon, filled while napping is on and outlined while it is off.
/// The Dev build adds a small dot in the corner so the two apps can be told apart in the menu bar.
enum MenuBarIcon {
    static func image(active: Bool) -> NSImage {
        let name = active ? "moon.zzz.fill" : "moon.zzz"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "Nappy")!.withSymbolConfiguration(config)!
        // Drawn into a plain bitmap in both builds: a bare symbol image can come out blank in a menu bar item.
        #if PUBLIC
        let extra: CGFloat = 0
        #else
        let extra: CGFloat = 3
        #endif
        let size = NSSize(width: symbol.size.width + extra, height: symbol.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
            #if !PUBLIC
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: size.width - 6, y: 0, width: 6, height: 6)).fill()
            #endif
            return true
        }
        image.isTemplate = true
        return image
    }
}
