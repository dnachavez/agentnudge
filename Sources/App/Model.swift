import Foundation

enum Paths {
    static let home = URL(fileURLWithPath: NSHomeDirectory())
    static let claude = home.appendingPathComponent(".claude")
    static let sessions = claude.appendingPathComponent("sessions")
    static let projects = claude.appendingPathComponent("projects")
    static let data = home.appendingPathComponent(".agentnudge")
    static let hooks = data.appendingPathComponent("hooks")
    static let status = data.appendingPathComponent("status")
    static let usage = data.appendingPathComponent("usage.json")
    static let bin = data.appendingPathComponent("bin")
    static let state = data.appendingPathComponent("state.json")
}

enum Bucket: String, CaseIterable, Identifiable {
    case needsYou = "Needs you"
    case inProgress = "In progress"
    case idle = "Idle"
    case later = "Later"
    case done = "Done"

    var id: String { rawValue }
}

struct Subagent: Identifiable, Hashable {
    let id: String
    let description: String
    let agentType: String
    let model: String?
}

enum Agent: String {
    case claude, codex
}

struct AgentThread: Identifiable, Equatable {
    let id: String
    var agent: Agent = .claude
    var pid: Int32?
    var cwd: String
    var project: String
    var branch: String?
    var title: String
    /// Claude Code's own recap when it is the newest thing in the transcript, else the last reply.
    var summary: String?
    var summaryIsRecap: Bool
    var mode: String?
    /// busy, shell, idle, waiting, ended, or whatever Claude Code reports.
    var status: String
    var waitingReason: String?
    var lastActivity: Date
    var kind: String
    var subagents: [Subagent]
    /// Percent of the context window in use, from the status line.
    var context: Double? = nil
    var bucket: Bucket = .inProgress
}

/// Plan usage as Claude Code's status line last reported it.
struct Usage: Equatable {
    var fiveHour: Double?
    var fiveHourReset: Date?
    var sevenDay: Double?
    var sevenDayReset: Date?
    var updated: Date

    var isEmpty: Bool { fiveHour == nil && sevenDay == nil }
}

/// Where the indicator lives. The menu bar icon can be on alongside any of them.
enum Placement: String, Codable, CaseIterable {
    case corner, free, notch, menuBarOnly

    var label: String {
        switch self {
        case .corner: return "Corner"
        case .free: return "Free"
        case .notch: return "Notch"
        case .menuBarOnly: return "Off"
        }
    }
}

enum Corner: String, Codable, CaseIterable {
    case bottomRight, bottomLeft, topRight, topLeft

    var label: String {
        switch self {
        case .bottomRight: return "Bottom right"
        case .bottomLeft: return "Bottom left"
        case .topRight: return "Top right"
        case .topLeft: return "Top left"
        }
    }

    var isBottom: Bool { self == .bottomRight || self == .bottomLeft }
    var isRight: Bool { self == .bottomRight || self == .topRight }
}

/// What the person decided, kept in ~/.agentnudge/state.json. A decision about a
/// thread (later, done) holds only until that thread does something new.
struct PersistedState: Codable {
    var later: [String: Double] = [:]
    var done: [String: Double] = [:]
    var placement: Placement = .corner
    /// Where the tray was dragged to in Free mode: its bottom-left corner, in screen points.
    var freeX: Double?
    var freeY: Double?
    var corner: Corner = .bottomRight
    var showMenuBar: Bool = true
    var hideInTerminal: Bool = true
    /// A finished session that has heard nothing from you for this long moves from Needs You to Idle.
    var idleMinutes: Int = 20
    /// Settings opens by itself once, on first launch, so people can choose where the indicator goes.
    var onboarded: Bool = false
    /// Folders the launcher offers, newest first. Filled from the sessions it sees.
    var workspaces: [String] = []
    /// What the launcher types into a new terminal. `{branch}` is replaced by the branch name.
    var claudeCommand = "claude"
    var branchCommand = "claude --worktree {branch}"
    var codexCommand = "codex"

    static let idleChoices = [10, 20, 30, 60]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        later = try c.decodeIfPresent([String: Double].self, forKey: .later) ?? [:]
        done = try c.decodeIfPresent([String: Double].self, forKey: .done) ?? [:]
        placement = try c.decodeIfPresent(Placement.self, forKey: .placement) ?? .corner
        freeX = try c.decodeIfPresent(Double.self, forKey: .freeX)
        freeY = try c.decodeIfPresent(Double.self, forKey: .freeY)
        corner = try c.decodeIfPresent(Corner.self, forKey: .corner) ?? .bottomRight
        showMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showMenuBar) ?? true
        hideInTerminal = try c.decodeIfPresent(Bool.self, forKey: .hideInTerminal) ?? true
        idleMinutes = try c.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? 20
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? false
        workspaces = try c.decodeIfPresent([String].self, forKey: .workspaces) ?? []
        claudeCommand = try c.decodeIfPresent(String.self, forKey: .claudeCommand) ?? "claude"
        branchCommand = try c.decodeIfPresent(String.self, forKey: .branchCommand) ?? "claude --worktree {branch}"
        codexCommand = try c.decodeIfPresent(String.self, forKey: .codexCommand) ?? "codex"
    }

    static func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: Paths.state) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    func save() {
        try? FileManager.default.createDirectory(at: Paths.data, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Paths.state, options: .atomic)
        }
    }
}
