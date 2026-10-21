import AppKit

/// Talks to Ghostty through its AppleScript dictionary (Ghostty 1.3 or later): finds the
/// terminal a session runs in, focuses it, and opens new tabs. Other terminals fall back
/// to bringing the app forward, and launches fall back to Terminal.
enum Ghostty {
    static let bundleID = "com.mitchellh.ghostty"

    struct Terminal {
        let id: String
        let name: String
        let cwd: String
    }

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Runs AppleScript in `osascript`, off the main thread, so a slow answer or the
    /// one-time permission prompt never stalls the UI.
    static func run(_ source: String, completion: ((String?) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async { completion?(nil) }
                return
            }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let ok = process.terminationStatus == 0
            DispatchQueue.main.async { completion?(ok ? text : nil) }
        }
    }

    static func terminals(_ completion: @escaping ([Terminal]?) -> Void) {
        let script = """
        tell application id "\(bundleID)"
            set out to ""
            repeat with t in terminals
                set out to out & (id of t) & (ASCII character 31) & (name of t) & (ASCII character 31) & (working directory of t) & linefeed
            end repeat
            return out
        end tell
        """
        run(script) { text in
            guard let text else { return completion(nil) }
            let unit = Character(UnicodeScalar(31))
            let list = text.split(separator: "\n").compactMap { line -> Terminal? in
                let parts = line.split(separator: unit, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { return nil }
                return Terminal(id: parts[0], name: parts[1], cwd: parts[2])
            }
            completion(list)
        }
    }

    /// The terminal a session most likely runs in: same folder first, then the title
    /// Claude Code puts on its tab ("✳ title" when idle, a spinner while working).
    static func match(_ thread: AgentThread, in terminals: [Terminal]) -> Terminal? {
        let cwd = normalized(thread.cwd)
        let title = thread.title.lowercased()
        func plain(_ name: String) -> String {
            var n = name
            if let first = n.unicodeScalars.first, !first.isASCII { n = String(n.drop(while: { !$0.isASCII || $0 == " " })) }
            return n.trimmingCharacters(in: .whitespaces).lowercased()
        }
        func isAgentTab(_ name: String) -> Bool { name.unicodeScalars.first.map { !$0.isASCII } ?? false }

        let sameFolder = terminals.filter { normalized($0.cwd) == cwd }
        let pool = sameFolder.isEmpty ? terminals : sameFolder
        if let exact = pool.first(where: { plain($0.name) == title }) { return exact }
        if let close = pool.first(where: {
            let name = plain($0.name)
            return isAgentTab($0.name) && !name.isEmpty && (name.contains(title) || title.contains(name))
        }) { return close }
        if sameFolder.count == 1 { return sameFolder[0] }
        return sameFolder.first(where: { isAgentTab($0.name) })
    }

    /// Focuses the exact terminal a session runs in. Ghostty doesn't say which process runs
    /// in which terminal, so this asks the session's own tty: it briefly sets the tab title
    /// to a one-off marker, finds the terminal now showing it, puts the title back, and
    /// focuses that terminal. Folder and title matching is the fallback.
    static func reveal(_ thread: AgentThread, tty: String?, otherwise: @escaping () -> Void) {
        terminals { before in
            guard let before, !before.isEmpty else { return otherwise() }
            func byGuess() {
                if let guess = match(thread, in: before) { focus(guess) } else { otherwise() }
            }
            guard let tty, let handle = FileHandle(forWritingAtPath: tty) else { return byGuess() }
            let marker = "agentnudge-\(UUID().uuidString.prefix(8))"
            handle.write(title(marker))

            func look(_ attempt: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    terminals { after in
                        if let hit = after?.first(where: { $0.name.contains(marker) }) {
                            handle.write(title(before.first { $0.id == hit.id }?.name ?? ""))
                            try? handle.close()
                            focus(hit)
                        } else if attempt < 10 {
                            look(attempt + 1)
                        } else {
                            try? handle.close()
                            byGuess()
                        }
                    }
                }
            }
            look(0)
        }
    }

    /// The escape sequence that sets a terminal's title (OSC 2).
    private static func title(_ text: String) -> Data {
        Data("\u{1b}]2;\(text)\u{07}".utf8)
    }

    static func focus(_ terminal: Terminal) {
        run("tell application id \"\(bundleID)\" to focus (first terminal whose id is \(quoted(terminal.id)))")
    }

    /// A new tab in the front Ghostty window (or a new window), in `folder`, typing `command`.
    static func open(folder: String, command: String?) {
        if !isInstalled {
            var line = "cd \(shellQuoted(folder))"
            if let command, !command.isEmpty { line += " && \(command)" }
            run("tell application \"Terminal\"\n activate\n do script \(quoted(line))\nend tell")
            return
        }
        let input = (command ?? "").isEmpty ? "" : "set initial input of cfg to \(quoted(command!)) & return"
        run("""
        tell application id "\(bundleID)"
            set cfg to new surface configuration
            set initial working directory of cfg to \(quoted(folder))
            \(input)
            if (count of windows) > 0 then
                new tab in front window with configuration cfg
            else
                new window with configuration cfg
            end if
            activate
        end tell
        """)
    }

    private static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// An AppleScript string literal.
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
