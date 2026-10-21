import AppKit
import ApplicationServices

/// How much empty menu bar there is either side of the notch, so the notch wings never
/// cover anything. Right of the notch, the menu bar icons are status windows whose
/// bounds anyone may read. Left of it are the front app's menus, which only the
/// Accessibility API can measure; without that permission the left side is assumed to
/// have room for a small wing.
enum MenuBarSpace {
    private static var menusCache: (pid: pid_t, at: Date, maxX: CGFloat?)?

    static func free(beside notch: NSRect) -> (left: CGFloat, right: CGFloat) {
        (left: freeLeft(of: notch), right: freeRight(of: notch))
    }

    private static func freeRight(of notch: NSRect) -> CGFloat {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var nearest = CGFloat.greatestFiniteMagnitude
        for w in windows where (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)) {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let h = b["Height"],
                  y <= 1, h <= notch.height + 2, x >= notch.maxX - 1 else { continue }
            nearest = min(nearest, x)
        }
        return nearest == .greatestFiniteMagnitude ? 200 : nearest - notch.maxX
    }

    private static func freeLeft(of notch: NSRect) -> CGFloat {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return NotchView.wing + 6 }
        let pid = app.processIdentifier
        if let cache = menusCache, cache.pid == pid, Date().timeIntervalSince(cache.at) < 5 {
            return cache.maxX.map { notch.minX - $0 } ?? 200
        }
        let maxX = lastMenuEdge(pid: pid, before: notch.minX)
        menusCache = (pid, Date(), maxX)
        return maxX.map { notch.minX - $0 } ?? 200
    }

    /// The right edge of the front app's last menu title left of the notch.
    private static func lastMenuEdge(pid: pid_t, before limit: CGFloat) -> CGFloat? {
        let app = AXUIElementCreateApplication(pid)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return nil }
        var edge: CGFloat?
        for item in items {
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success else { continue }
            var origin = CGPoint.zero
            var extent = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
            if origin.x < limit { edge = max(edge ?? 0, origin.x + extent.width) }
        }
        return edge
    }
}
