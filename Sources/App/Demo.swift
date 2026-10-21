import Foundation

/// Sample sessions for README screenshots (`AgentNudge --snapshot <dir> --demo`), so no
/// real project, prompt or reply ever ends up in an image.
enum Demo {
    static func threads(now: Date = Date()) -> [AgentThread] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func thread(_ id: String, _ title: String, project: String, branch: String?, mode: String?,
                    status: String, minutes: Double, summary: String?, reason: String? = nil,
                    agent: Agent = .claude, subagents: [Subagent] = [], context: Double? = nil) -> AgentThread {
            AgentThread(id: id, agent: agent, pid: nil, cwd: NSHomeDirectory() + "/dev/\(project)", project: project, branch: branch,
                        title: title, summary: summary, summaryIsRecap: false, mode: mode, status: status,
                        waitingReason: reason, lastActivity: ago(minutes), kind: agent == .codex ? "codex" : "interactive",
                        subagents: subagents, context: context)
        }
        return [
            thread("d1", "Add rate limiting to the public API", project: "api", branch: "feat/rate-limits",
                   mode: "bypassPermissions", status: "waiting", minutes: 2,
                   summary: "Token bucket is in place behind a feature flag, with tests for burst and refill.",
                   reason: "Asks: limit per API key or per IP address?", context: 38),
            thread("d2", "Fix the flaky checkout test", project: "web", branch: "fix/checkout-flake",
                   mode: "acceptEdits", status: "idle", minutes: 6,
                   summary: "Root cause was a timer the test never advanced. Fixed with a fake clock; 200 runs pass.",
                   context: 22),
            thread("d3", "Move billing to Stripe Checkout", project: "billing", branch: "billing/stripe-checkout",
                   mode: "plan", status: "busy", minutes: 1,
                   summary: "Mapping the webhook handlers before writing the migration plan.",
                   subagents: [Subagent(id: "s1", description: "map webhook handlers", agentType: "Explore", model: nil),
                               Subagent(id: "s2", description: "draft migration tests", agentType: "general-purpose", model: nil)],
                   context: 41),
            thread("d4", "Draft the Q4 changelog", project: "docs", branch: nil, mode: "on request", status: "busy",
                   minutes: 3, summary: "Grouping 48 merged pull requests by area.", agent: .codex),
            thread("d5", "Upgrade to React 19", project: "web", branch: "chore/react-19", mode: "bypassPermissions",
                   status: "idle", minutes: 95,
                   summary: "All pages build. Two components still use the legacy context API; notes are in the PR."),
            thread("d6", "Write the onboarding email sequence", project: "growth", branch: nil, mode: "default",
                   status: "idle", minutes: 300, summary: "Five emails drafted in docs/onboarding.md."),
        ]
    }

    static func usage(now: Date = Date()) -> Usage {
        Usage(fiveHour: 34, fiveHourReset: now.addingTimeInterval(2 * 3600 + 900),
              sevenDay: 18, sevenDayReset: now.addingTimeInterval(4 * 86400), updated: now)
    }

    static let workspaces = ["api", "web", "billing", "docs"].map { NSHomeDirectory() + "/dev/" + $0 }
}
