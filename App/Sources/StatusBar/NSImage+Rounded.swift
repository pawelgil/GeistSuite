import AppKit

extension NSImage {
    func roundedSquircle(size: NSSize, cornerRadius: CGFloat) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        defer { result.unlockFocus() }
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                                xRadius: cornerRadius, yRadius: cornerRadius)
        path.addClip()
        draw(in: NSRect(origin: .zero, size: size),
             from: NSRect(origin: .zero, size: self.size),
             operation: .sourceOver,
             fraction: 1.0)
        return result
    }
}
