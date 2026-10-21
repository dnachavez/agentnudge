import AppKit

/// Copies the hook helper out of the app bundle to ~/.agentnudge/bin, the one path
/// the Claude Code hooks call, so moving or updating the app never breaks them.
enum HookHelper {
    static func install() {
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agentnudge-hook")
        let dest = Paths.bin.appendingPathComponent("agentnudge-hook")
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        if let a = try? Data(contentsOf: source), let b = try? Data(contentsOf: dest), a == b { return }
        try? fm.createDirectory(at: Paths.bin, withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try? fm.copyItem(at: source, to: dest)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SessionStore?
    private var controller: Controller?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        HookHelper.install()
        let store = SessionStore()
        self.store = store
        let controller = Controller(store: store)
        self.controller = controller
        store.start()
        if !store.state.onboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { controller.showSettings() }
        }
    }

    /// Opening the app again while it runs shows Settings, since it has no window of its own.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showSettings()
        return false
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        controller?.handle(url)
    }
}

MainActor.assumeIsolated {
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
        Snapshot.run(to: CommandLine.arguments[i + 1])
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
