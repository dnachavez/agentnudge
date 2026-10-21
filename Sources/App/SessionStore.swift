import AppKit
import Combine
import Foundation

/// One running Claude Code process, as Claude Code itself records it in ~/.claude/sessions.
private struct RegistryEntry {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let status: String
    let statusUpdatedAt: Double
    let updatedAt: Double
    let kind: String
    let name: String?
    let nameSource: String?
}

/// What the AgentNudge hook last saw for a session, in ~/.agentnudge/hooks/<id>.json.
private struct HookState {
    let ts: Double
    let permissionMode: String?
    let waiting: Bool
    let reason: String?
    let transcriptPath: String?
}

struct ScanResult {
    let threads: [AgentThread]
    let hosts: Set<pid_t>
    let usage: Usage?
}

/// Reads every source off the main thread: the session registry, the hook files, and the
/// tail of each transcript. It knows nothing about the person's choices; the store sorts.
final class SessionScanner {
    private let transcripts = TranscriptReader()
    private let codex = CodexReader()
    private var lastLive: [String: AgentThread] = [:]
    private var ended: [String: AgentThread] = [:]
    private var hostCache: [Int32: pid_t] = [:]

    func scan() -> ScanResult {
        let now = Date()
        let hooks = readHooks()
        let contexts = readContexts()
        var live: [String: AgentThread] = [:]
        var hosts: Set<pid_t> = []

        for r in readRegistry() {
            let hook = hooks[r.sessionId]
            let url = transcripts.locate(sessionId: r.sessionId, cwd: r.cwd, hint: hook?.transcriptPath)
            let info = url.map { transcripts.info(for: $0) } ?? TranscriptInfo()

            var status = r.status
            var reason: String?
            if r.status == "waiting" || r.status == "blocked" {
                status = "waiting"
                reason = "Waiting for you"
            }
            // The hook knows about questions and permission prompts; a turn that ended after it wins.
            if let hook, hook.waiting, !(r.status == "idle" && r.statusUpdatedAt > hook.ts + 1500) {
                status = "waiting"
                reason = hook.reason ?? reason
            }

            var mode = info.mode
            if let hook, let hookMode = hook.permissionMode,
               hook.ts / 1000 >= info.modified.timeIntervalSince1970 - 1 || mode == nil {
                mode = hookMode
            }

            let named = r.nameSource != nil && r.nameSource != "derived" ? r.name : nil
            let last = max(r.statusUpdatedAt, hook?.ts ?? 0)

            live[r.sessionId] = AgentThread(
                id: r.sessionId,
                pid: r.pid,
                cwd: r.cwd,
                project: SessionStore.projectName(r.cwd),
                branch: (info.branch == "HEAD" ? nil : info.branch) ?? SessionStore.worktreeName(r.cwd),
                title: named ?? info.title ?? r.name ?? SessionStore.projectName(r.cwd),
                summary: info.summary,
                summaryIsRecap: info.summaryIsRecap,
                mode: mode,
                status: status,
                waitingReason: reason,
                lastActivity: Date(timeIntervalSince1970: last / 1000),
                kind: r.kind,
                subagents: url.map { transcripts.runningSubagents(transcript: $0) } ?? [],
                context: contexts[r.sessionId]
            )
            if let app = hostApp(for: r.pid) { hosts.insert(app) }
        }

        // Codex threads have no process to watch; they stay listed while active in the last day.
        let codexThreads = codex.threads(now: now)

        for (id, t) in lastLive where live[id] == nil {
            var gone = t
            gone.status = "ended"
            gone.waitingReason = nil
            gone.subagents = []
            gone.lastActivity = now
            ended[id] = gone
        }
        for id in live.keys { ended[id] = nil }
        ended = ended.filter { now.timeIntervalSince($0.value.lastActivity) < 24 * 3600 }
        lastLive = live
        return ScanResult(threads: Array(live.values) + Array(ended.values) + codexThreads, hosts: hosts, usage: readUsage())
    }

    private func readUsage() -> Usage? {
        guard let data = try? Data(contentsOf: Paths.usage),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func date(_ key: String) -> Date? { (obj[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
        let usage = Usage(
            fiveHour: (obj["fiveHour"] as? NSNumber)?.doubleValue,
            fiveHourReset: date("fiveHourReset"),
            sevenDay: (obj["sevenDay"] as? NSNumber)?.doubleValue,
            sevenDayReset: date("sevenDayReset"),
            updated: date("ts") ?? .distantPast)
        return usage.isEmpty ? nil : usage
    }

    /// Context use per session, from ~/.agentnudge/status/<id>.json.
    private func readContexts() -> [String: Double] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Paths.status, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        var out: [String: Double] = [:]
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            if let modified, modified < weekAgo {
                try? fm.removeItem(at: file)
                continue
            }
            guard let data = try? Data(contentsOf: file),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let context = (obj["context"] as? NSNumber)?.doubleValue else { continue }
            out[file.deletingPathExtension().lastPathComponent] = context
        }
        return out
    }

    private func hostApp(for pid: Int32) -> pid_t? {
        if let cached = hostCache[pid] { return cached }
        guard let app = TerminalFinder.hostingApp(for: pid) else { return nil }
        hostCache[pid] = app.processIdentifier
        return app.processIdentifier
    }

    private func readRegistry() -> [RegistryEntry] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil)) ?? []
        var bySession: [String: RegistryEntry] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value,
                  let sid = obj["sessionId"] as? String,
                  let cwd = obj["cwd"] as? String else { continue }
            guard kill(pid, 0) == 0 || errno == EPERM else { continue }
            let entry = RegistryEntry(
                pid: pid,
                sessionId: sid,
                cwd: cwd,
                status: obj["status"] as? String ?? "busy",
                statusUpdatedAt: (obj["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? (obj["updatedAt"] as? NSNumber)?.doubleValue ?? 0,
                updatedAt: (obj["updatedAt"] as? NSNumber)?.doubleValue ?? 0,
                kind: obj["kind"] as? String ?? "interactive",
                name: obj["name"] as? String,
                nameSource: obj["nameSource"] as? String
            )
            if let existing = bySession[sid], existing.updatedAt >= entry.updatedAt { continue }
            bySession[sid] = entry
        }
        return Array(bySession.values)
    }

    private func readHooks() -> [String: HookState] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Paths.hooks, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [String: HookState] = [:]
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            if let modified, modified < weekAgo {
                try? fm.removeItem(at: file)
                continue
            }
            guard let data = try? Data(contentsOf: file),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            out[file.deletingPathExtension().lastPathComponent] = HookState(
                ts: (obj["ts"] as? NSNumber)?.doubleValue ?? 0,
                permissionMode: obj["permissionMode"] as? String,
                waiting: obj["waiting"] as? Bool ?? false,
                reason: obj["reason"] as? String,
                transcriptPath: obj["transcriptPath"] as? String
            )
        }
        return out
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var threads: [AgentThread] = []
    @Published private(set) var state: PersistedState
    @Published private(set) var usage: Usage?

    /// Pids of the apps hosting a live session, so the indicator can step aside in them.
    private(set) var hostAppPids: Set<pid_t> = []

    private let scanner = SessionScanner()
    private let queue = DispatchQueue(label: "agentnudge.scan", qos: .utility)
    private var scanning = false
    private var scanAgain = false
    private var timer: Timer?

    init() {
        state = PersistedState.load() ?? PersistedState()
    }

    /// Shows the `Demo` sessions and never reads or writes this Mac's data. For screenshots.
    init(demo: Void) {
        var sample = PersistedState()
        sample.workspaces = Demo.workspaces
        sample.onboarded = true
        state = sample
        usage = Demo.usage()
        publish(Demo.threads())
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func count(_ bucket: Bucket) -> Int { threads.filter { $0.bucket == bucket }.count }

    func threads(in bucket: Bucket) -> [AgentThread] { threads.filter { $0.bucket == bucket } }

    // MARK: Reading

    /// Scans in the background and publishes on the main thread. Never blocks the UI.
    func refresh() {
        if scanning {
            scanAgain = true
            return
        }
        scanning = true
        let scanner = self.scanner
        queue.async {
            let result = scanner.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.apply(result) }
            }
        }
    }

    /// For snapshots, which render once and exit.
    func refreshNow() {
        apply(scanner.scan())
    }

    private func apply(_ result: ScanResult) {
        scanning = false
        hostAppPids = result.hosts
        if result.usage != usage { usage = result.usage }
        publish(result.threads)
        rememberWorkspaces(result.threads)
        pruneState(keeping: Set(result.threads.map(\.id)))
        if scanAgain {
            scanAgain = false
            refresh()
        }
    }

    private func publish(_ raw: [AgentThread]) {
        let now = Date()
        var all = raw
        for i in all.indices { classify(&all[i], now: now) }
        all.sort { $0.lastActivity > $1.lastActivity }
        if all != threads { threads = all }
    }

    // MARK: Decisions

    /// Opening a session only brings its terminal forward; it stays in Needs you until it
    /// does something new or goes idle.
    func open(_ t: AgentThread) {
        TerminalFinder.bringForward(t)
    }

    // MARK: Launcher

    enum Launch: String, CaseIterable {
        case claude = "Claude", branch = "Branch", codex = "Codex", shell = "Shell"
    }

    /// A branch name as Git and a shell both accept it, or nil.
    static func branchName(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.range(of: "^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$", options: .regularExpression) != nil ? t : nil
    }

    func command(for launch: Launch, branch: String?) -> String? {
        switch launch {
        case .claude: return state.claudeCommand
        case .codex: return state.codexCommand
        case .shell: return nil
        case .branch:
            guard let branch = branch.flatMap(Self.branchName) else { return nil }
            return state.branchCommand.replacingOccurrences(of: "{branch}", with: branch)
        }
    }

    func launch(_ launch: Launch, in folder: String, branch: String?) {
        if launch == .branch && branch.flatMap(Self.branchName) == nil { return }
        Ghostty.open(folder: folder, command: command(for: launch, branch: branch))
        // The folder used most recently goes to the top.
        state.workspaces.removeAll { $0 == folder }
        state.workspaces.insert(folder, at: 0)
        commit()
    }

    func addWorkspace(_ folder: String) {
        state.workspaces.removeAll { $0 == folder }
        state.workspaces.insert(folder, at: 0)
        commit()
    }

    func removeWorkspace(_ folder: String) {
        state.workspaces.removeAll { $0 == folder }
        commit()
    }

    func setCommand(_ launch: Launch, _ command: String) {
        switch launch {
        case .claude: state.claudeCommand = command
        case .branch: state.branchCommand = command
        case .codex: state.codexCommand = command
        case .shell: return
        }
        state.save()
    }

    /// Adds the repository folders of the Claude Code sessions it sees, so the launcher offers them.
    private func rememberWorkspaces(_ threads: [AgentThread]) {
        let home = NSHomeDirectory()
        var added = false
        for t in threads where t.agent == .claude {
            var root = t.cwd
            if let r = root.range(of: "/.claude/worktrees/") { root = String(root[..<r.lowerBound]) }
            guard root.hasPrefix(home + "/"), !state.workspaces.contains(root) else { continue }
            state.workspaces.append(root)
            added = true
        }
        if added {
            state.workspaces = Array(state.workspaces.prefix(20))
            state.save()
        }
    }

    func markLater(_ t: AgentThread) {
        state.later[t.id] = Date().timeIntervalSince1970
        state.done[t.id] = nil
        commit()
    }

    func markDone(_ t: AgentThread) {
        state.done[t.id] = Date().timeIntervalSince1970
        state.later[t.id] = nil
        commit()
    }

    func restore(_ t: AgentThread) {
        state.later[t.id] = nil
        state.done[t.id] = nil
        commit()
    }

    func setPlacement(_ placement: Placement) {
        state.placement = placement
        commit()
    }

    /// Remembers where the tray was dragged. Saved without a refresh: nothing else changes.
    func setFreeOrigin(_ origin: CGPoint) {
        state.freeX = Double(origin.x)
        state.freeY = Double(origin.y)
        state.save()
    }

    func setCorner(_ corner: Corner) {
        state.corner = corner
        commit()
    }

    func setShowMenuBar(_ on: Bool) {
        state.showMenuBar = on
        commit()
    }

    func setHideInTerminal(_ on: Bool) {
        state.hideInTerminal = on
        commit()
    }

    func setIdleMinutes(_ minutes: Int) {
        state.idleMinutes = minutes
        commit()
    }

    func markOnboarded() {
        state.onboarded = true
        commit()
    }

    /// Whether ~/.claude/settings.json calls the AgentNudge hook.
    var hooksInstalled: Bool {
        let settings = Paths.claude.appendingPathComponent("settings.json")
        guard let text = try? String(contentsOf: settings, encoding: .utf8) else { return false }
        return text.contains("agentnudge-hook")
    }

    /// Saves, re-sorts what is already on screen at once, then rescans.
    private func commit() {
        state.save()
        publish(threads)
        refresh()
    }

    /// Done and Later win until the session does something new. A question or permission
    /// prompt always needs you. A finished turn needs you for `idleMinutes`, then it is Idle.
    /// "shell" means the turn is over but a background command is still running, which
    /// counts as work only while it is recent: a loop left behind for days is not progress.
    private func classify(_ t: inout AgentThread, now: Date) {
        let last = t.lastActivity.timeIntervalSince1970
        let quiet = now.timeIntervalSince(t.lastActivity) >= Double(state.idleMinutes * 60)
        if t.status == "ended" {
            t.bucket = .done
        } else if let d = state.done[t.id], d >= last {
            t.bucket = .done
        } else if let l = state.later[t.id], l >= last {
            t.bucket = .later
        } else if t.status == "waiting" {
            t.bucket = .needsYou
        } else if t.status == "idle" {
            t.bucket = quiet ? .idle : .needsYou
        } else if t.status == "shell" && quiet {
            t.bucket = .idle
            t.waitingReason = "Background command still running, quiet for \(Self.duration(now.timeIntervalSince(t.lastActivity)))"
        } else {
            t.bucket = .inProgress
        }
    }

    private func pruneState(keeping ids: Set<String>) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970
        let keep: (String, Double) -> Bool = { id, ts in ids.contains(id) || ts > cutoff }
        let later = state.later.filter { keep($0.key, $0.value) }
        let done = state.done.filter { keep($0.key, $0.value) }
        if later.count != state.later.count || done.count != state.done.count {
            state.later = later
            state.done = done
            state.save()
        }
    }

    // MARK: Naming

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    /// Folders under home that usually hold repositories, so `~/dev/web/api` reads as `web/api`.
    nonisolated static let codeRoots = ["dev", "Developer", "code", "Code", "src", "projects", "Projects", "repos", "git", "work"]

    /// `my-app`, `work/api`, `~/dev`: the workspace a folder belongs to, worktrees folded into their repo.
    nonisolated static func projectName(_ cwd: String) -> String {
        var path = cwd
        if let r = path.range(of: "/.claude/worktrees/") { path = String(path[..<r.lowerBound]) }
        let home = NSHomeDirectory()
        for root in codeRoots {
            let dir = home + "/" + root
            if path == dir { return "~/" + root }
            if path.hasPrefix(dir + "/") { return String(path.dropFirst(dir.count + 1)) }
        }
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        // Outside home (temp sandboxes and the like) the last two folders say enough.
        let parts = path.split(separator: "/")
        return parts.count > 2 ? "…/" + parts.suffix(2).joined(separator: "/") : path
    }

    nonisolated static func worktreeName(_ cwd: String) -> String? {
        guard let r = cwd.range(of: "/.claude/worktrees/") else { return nil }
        let rest = String(cwd[r.upperBound...])
        return rest.split(separator: "/").last.map(String.init)
    }
}
