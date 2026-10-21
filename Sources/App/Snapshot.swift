import AppKit
import SwiftUI

/// `AgentNudge --snapshot <dir>` renders the indicators, the session list and Settings from
/// live data to PNGs and exits, to check layout without screen recording. The frosted
/// backdrop doesn't render offscreen, so everything sits on a dark desktop color here.
@MainActor
enum Snapshot {
    static func run(to dir: String) {
        _ = NSApplication.shared
        let store: SessionStore
        if CommandLine.arguments.contains("--demo") {
            store = SessionStore(demo: ())
        } else {
            store = SessionStore()
            store.refreshNow()
        }
        render(TrayView(store: store, onTap: {}), "tray", dir)
        for bucket in [Bucket.needsYou, .inProgress, .idle] {
            let name = bucket.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
            render(ListView(store: store, onOpen: { _ in }, initialTab: bucket), "list-\(name)", dir)
        }
        render(SettingsPanel(store: store, onQuit: {}), "settings", dir)
        render(ListView(store: store, onOpen: { _ in }, initialTab: .needsYou, launching: true), "launcher", dir)
        render(NotchView(store: store, notchWidth: 200, notchHeight: 32, showChin: true, onTap: {}, onHover: { _ in }).padding(20), "notch", dir)
        let glyphs = HStack(spacing: 28) {
            ForEach([StatusGlyph.State.quiet, .running, .attention], id: \.self) { state in
                Image(nsImage: StatusGlyph.image(state)).renderingMode(.template).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 24).frame(height: 24).background(Color.black.opacity(0.85))
        render(glyphs.scaleEffect(4).frame(width: 220 * 4 / 2, height: 24 * 4), "menubar", dir)
    }

    private static func render<V: View>(_ view: V, _ name: String, _ dir: String) {
        let desk = Color(red: 0.20, green: 0.22, blue: 0.27)
        let host = NSHostingView(rootView: view.environment(\.snapshot, true).background(desk))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
