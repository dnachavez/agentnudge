import AppKit
import Darwin

/// Finds the app a Claude Code process runs inside (Ghostty, cmux, VS Code…) by
/// walking up its parent processes.
enum TerminalFinder {
    static let knownTerminals: Set<String> = [
        "com.mitchellh.ghostty",
        "com.cmuxterm.app",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
    ]

    static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 1 ? ppid : nil
    }

    /// The controlling terminal of a process, like `/dev/ttys003`, or nil.
    static func ttyPath(for pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        let tty = String(cString: name)
        return tty.hasPrefix("tty") ? "/dev/" + tty : nil
    }

    static func hostingApp(for pid: pid_t) -> NSRunningApplication? {
        var current: pid_t? = pid
        var hops = 0
        while let p = current, hops < 24 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
                return app
            }
            current = parentPid(of: p)
            hops += 1
        }
        return nil
    }

    /// The ChatGPT app hosts Codex desktop threads.
    static let codexAppID = "com.openai.chat"

    /// Brings a session's own place forward: its exact Ghostty tab when it runs in Ghostty,
    /// the Codex app for a Codex desktop thread, otherwise the app it runs in.
    static func bringForward(_ thread: AgentThread) {
        if thread.agent == .codex && thread.pid == nil {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: codexAppID) { activate(url) }
            return
        }
        guard let pid = thread.pid, let app = hostingApp(for: pid) else { return }
        guard app.bundleIdentifier == Ghostty.bundleID else {
            if let url = app.bundleURL { activate(url) } else { app.activate() }
            return
        }
        Ghostty.reveal(thread, tty: ttyPath(for: pid)) {
            if let url = app.bundleURL { activate(url) }
        }
    }

    private static func activate(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
