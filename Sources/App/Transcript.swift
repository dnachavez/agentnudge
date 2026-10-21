import Foundation

struct TranscriptInfo {
    var title: String?
    var summary: String?
    var summaryIsRecap = false
    var mode: String?
    var branch: String?
    var modified = Date.distantPast
}

/// Reads only the tail of each Claude Code transcript, and only when it changed.
final class TranscriptReader {
    private struct Cached {
        let modified: Date
        let size: UInt64
        let readAt: Date
        let info: TranscriptInfo
    }

    private static let tailBytes: UInt64 = 768 * 1024
    private static let minReread: TimeInterval = 3

    private var cache: [String: Cached] = [:]
    private var located: [String: URL] = [:]

    func locate(sessionId: String, cwd: String, hint: String?) -> URL? {
        let fm = FileManager.default
        if let hint, fm.fileExists(atPath: hint) { return URL(fileURLWithPath: hint) }
        if let known = located[sessionId], fm.fileExists(atPath: known.path) { return known }

        let encoded = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        let direct = Paths.projects.appendingPathComponent(encoded).appendingPathComponent("\(sessionId).jsonl")
        if fm.fileExists(atPath: direct.path) {
            located[sessionId] = direct
            return direct
        }
        let dirs = (try? fm.contentsOfDirectory(at: Paths.projects, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) {
                located[sessionId] = candidate
                return candidate
            }
        }
        return nil
    }

    func info(for url: URL) -> TranscriptInfo {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return TranscriptInfo() }

        if let hit = cache[url.path] {
            let unchanged = hit.modified == modified && hit.size == size
            if unchanged || Date().timeIntervalSince(hit.readAt) < Self.minReread { return hit.info }
        }
        var info = parseTail(url: url, size: size)
        info.modified = modified
        cache[url.path] = Cached(modified: modified, size: size, readAt: Date(), info: info)
        return info
    }

    private func parseTail(url: URL, size: UInt64) -> TranscriptInfo {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return TranscriptInfo() }
        defer { try? handle.close() }
        let offset = size > Self.tailBytes ? size - Self.tailBytes : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return TranscriptInfo() }

        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }

        var customTitle: String?
        var aiTitle: String?
        var recap: String?
        var lastText: String?
        var mode: String?
        var branch: String?

        for line in lines.reversed() {
            if aiTitle != nil && mode != nil && branch != nil && lastText != nil { break }

            if customTitle == nil, line.contains("\"type\":\"custom-title\""), let obj = json(line) {
                customTitle = obj["customTitle"] as? String ?? obj["title"] as? String
            }
            if aiTitle == nil, line.contains("\"type\":\"ai-title\""), let obj = json(line) {
                aiTitle = obj["aiTitle"] as? String
            }
            // A recap only counts while nothing newer was said after it.
            if recap == nil, lastText == nil, line.contains("\"away_summary\""), let obj = json(line),
               obj["subtype"] as? String == "away_summary" {
                recap = obj["content"] as? String
            }
            if mode == nil, line.contains("\"type\":\"permission-mode\""), let obj = json(line) {
                mode = obj["permissionMode"] as? String
            }
            if lastText == nil, line.contains("\"type\":\"assistant\""), let obj = json(line) {
                lastText = assistantText(obj)
            }
            if branch == nil, line.contains("\"gitBranch\":\""), let obj = json(line) {
                if let b = obj["gitBranch"] as? String, !b.isEmpty { branch = b }
            }
        }

        var info = TranscriptInfo()
        info.title = customTitle ?? aiTitle
        if let recap {
            info.summary = clean(recap)
            info.summaryIsRecap = true
        } else if let lastText {
            info.summary = clean(lastText)
        }
        info.mode = mode
        info.branch = branch
        return info
    }

    func runningSubagents(transcript: URL) -> [Subagent] {
        let fm = FileManager.default
        let dir = transcript.deletingPathExtension().appendingPathComponent("subagents")
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let now = Date()
        var out: [Subagent] = []
        for meta in files where meta.lastPathComponent.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: meta),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if obj["finished"] as? Bool == true { continue }
            // A crashed session leaves unfinished metadata behind; only recent logs count as running.
            let log = dir.appendingPathComponent(meta.lastPathComponent.replacingOccurrences(of: ".meta.json", with: ".jsonl"))
            let touched = (try? fm.attributesOfItem(atPath: log.path)[.modificationDate] as? Date) ?? nil
            guard let touched, now.timeIntervalSince(touched) < 15 * 60 else { continue }
            out.append(Subagent(
                id: meta.lastPathComponent,
                description: obj["description"] as? String ?? "subagent",
                agentType: obj["agentType"] as? String ?? "agent",
                model: obj["model"] as? String
            ))
        }
        return out.sorted { $0.id < $1.id }
    }

    private func json(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func assistantText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private func clean(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "(^|\\s)#+\\s", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        return s.count > 320 ? String(s.prefix(320)) + "…" : s
    }
}
