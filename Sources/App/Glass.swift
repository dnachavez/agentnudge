import AppKit
import SwiftUI

/// A panel's root view: the macOS menu material, masked to the panel's rounded shape, with
/// the SwiftUI content on top. The window is exactly the shape's size and the material is
/// masked to its corners, so nothing translucent shows outside the shape.
final class GlassHost<Content: View>: NSView {
    let host: IndicatorHost<Content>
    private let material = NSVisualEffectView()

    init(rootView: Content, radius: CGFloat) {
        host = IndicatorHost(rootView: rootView)
        super.init(frame: .zero)
        material.material = .menu
        material.blendingMode = .behindWindow
        material.state = .active
        material.appearance = NSAppearance(named: .darkAqua)
        material.maskImage = Self.mask(radius: radius)
        material.autoresizingMask = [.width, .height]
        host.autoresizingMask = [.width, .height]
        addSubview(material)
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var fittingSize: NSSize { host.fittingSize }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        material.frame = bounds
        host.frame = bounds
    }

    /// A stretchable rounded rectangle: its corners stay round at any size.
    private static func mask(radius r: CGFloat) -> NSImage {
        let edge = 2 * r + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}
