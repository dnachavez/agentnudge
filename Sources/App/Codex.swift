import Foundation
import SQLite3

/// Reads Codex threads (the desktop app and the CLI) touched in the last day from Codex's
/// own state database, and each thread's state from the tail of its rollout file.
final class CodexReader {
    private struct Tail {
        var status = "idle"
        var summary: String?
        var reason: String?
    }

    private var tails: [String: (modified: Date, size: UInt64, tail: Tail)] = [:]

    static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    }

    func threads(now: Date) -> [AgentThread] {
        guard let path = databasePath() else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
        select id, rollout_path, cwd, coalesce(nullif(name, ''), title), approval_mode,
               coalesce(git_branch, ''), updated_at_ms, source
        from threads where archived = 0 and updated_at_ms > ?
        order by updated_at_ms desc limit 30
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        // AGENTNUDGE_CODEX_HOURS widens the window, for testing against older threads.
        let hours = Double(ProcessInfo.processInfo.environment["AGENTNUDGE_CODEX_HOURS"] ?? "") ?? 24
        sqlite3_bind_int64(statement, 1, Int64((now.timeIntervalSince1970 - hours * 3600) * 1000))

        func text(_ i: Int32) -> String {
            sqlite3_column_text(statement, i).map { String(cString: $0) } ?? ""
        }

        var out: [AgentThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = text(0)
            let rollout = URL(fileURLWithPath: text(1))
            let cwd = text(2)
            let updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 6)) / 1000)
            let tail = self.tail(of: rollout, now: now)
            let branch = text(5)
            out.append(AgentThread(
                id: "codex:\(id)",
                agent: .codex,
                pid: nil,
                cwd: cwd,
                // The desktop app works in dated scratch folders under ~/Documents/Codex.
                project: cwd.contains("/Documents/Codex/") ? "Codex" : SessionStore.projectName(cwd),
                branch: branch.isEmpty ? nil : branch,
                title: Self.firstLine(text(3)),
                summary: tail.summary.map(Self.clean),
                summaryIsRecap: false,
                mode: Self.approvalName(text(4)),
                status: tail.status,
                waitingReason: tail.reason,
                lastActivity: updated,
                kind: text(7) == "cli" ? "codex-cli" : "codex",
                subagents: []))
        }
        return out
    }

    /// The newest `state_<n>.sqlite` Codex keeps.
    private func databasePath() -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.home.path)) ?? []
        let best = files
            .filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
            .max { (Int($0.dropFirst(6).dropLast(7)) ?? 0) < (Int($1.dropFirst(6).dropLast(7)) ?? 0) }
        return best.map { Self.home.appendingPathComponent($0).path }
    }

    /// The last decisive event in a rollout: a finished or aborted turn, a pending approval,
    /// or a turn still running. A turn that started but went quiet for ten minutes is idle.
    private func tail(of url: URL, now: Date) -> Tail {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return Tail() }
        if let hit = tails[url.path], hit.modified == modified, hit.size == size { return hit.tail }

        var tail = Tail()
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let window: UInt64 = 384 * 1024
            try? handle.seek(toOffset: size > window ? size - window : 0)
            let data = (try? handle.readToEnd()) ?? Data()
            var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            if size > window, !lines.isEmpty { lines.removeFirst() }
            var lastMessage: String?
            scan: for line in lines.reversed() where line.contains("\"event_msg\"") {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let type = payload["type"] as? String else { continue }
                if lastMessage == nil, type == "agent_message" { lastMessage = payload["message"] as? String }
                switch type {
                case "task_complete":
                    tail.status = "idle"
                    tail.summary = (payload["last_agent_message"] as? String) ?? lastMessage
                    break scan
                case "turn_aborted":
                    tail.status = "idle"
                    tail.summary = lastMessage
                    break scan
                case let t where t.contains("approval_request") || t == "request_user_input":
                    tail.status = "waiting"
                    tail.reason = "Waiting for your approval"
                    tail.summary = lastMessage
                    break scan
                case "task_started":
                    tail.status = now.timeIntervalSince(modified) < 600 ? "busy" : "idle"
                    tail.summary = lastMessage
                    break scan
                default:
                    continue
                }
            }
        }
        tails[url.path] = (modified, size, tail)
        return tail
    }

    private static func approvalName(_ mode: String) -> String? {
        switch mode {
        case "never": return "full auto"
        case "on-request": return "on request"
        case "on-failure": return "on failure"
        case "untrusted": return "untrusted"
        case "": return nil
        default: return mode
        }
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? "Codex thread"
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    private static func clean(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return s.count > 320 ? String(s.prefix(320)) + "…" : s
    }
}
