import Foundation

// Called by Claude Code hooks as `agentnudge-hook <Event>`, with the hook's JSON on stdin.
// It records the session's latest state in ~/.agentnudge/hooks/<session_id>.json for the
// app to read. It never prints and always exits 0, so it can never block or steer Claude.

let event = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let input = FileHandle.standardInput.readDataToEndOfFile()

guard let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      let sid = obj["session_id"] as? String,
      !sid.isEmpty,
      sid.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { exit(0) }

let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".agentnudge")

/// Epoch seconds from a number (seconds or milliseconds) or an ISO 8601 string.
func epoch(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue > 1e12 ? n.doubleValue / 1000 : n.doubleValue }
    if let s = value as? String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970
    }
    return nil
}

func write(_ object: [String: Any], to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
        try? data.write(to: url, options: .atomic)
    }
}

// `agentnudge-hook StatusLine`, fed the status line's JSON by the person's status line
// script: plan usage for everyone, and this session's context use. It runs every few
// seconds, so it never touches the session's activity record.
if event == "StatusLine" {
    let now = Date().timeIntervalSince1970
    if let limits = obj["rate_limits"] as? [String: Any] {
        var usage: [String: Any] = ["ts": now]
        for (key, name) in [("five_hour", "fiveHour"), ("seven_day", "sevenDay")] {
            guard let window = limits[key] as? [String: Any] else { continue }
            if let used = window["used_percentage"] as? NSNumber { usage[name] = used.doubleValue }
            if let reset = epoch(window["resets_at"] ?? window["reset_at"] ?? window["resets"]) { usage[name + "Reset"] = reset }
        }
        write(usage, to: home.appendingPathComponent("usage.json"))
    }
    var status: [String: Any] = ["ts": now]
    if let used = (obj["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber { status["context"] = used.doubleValue }
    if let cost = (obj["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber { status["cost"] = cost.doubleValue }
    write(status, to: home.appendingPathComponent("status/\(sid).json"))
    exit(0)
}

let dir = home.appendingPathComponent("hooks")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let file = dir.appendingPathComponent("\(sid).json")

var state: [String: Any] = [:]
if let data = try? Data(contentsOf: file),
   let old = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
    state = old
}

state["event"] = event
state["ts"] = Int(Date().timeIntervalSince1970 * 1000)
if let mode = obj["permission_mode"] as? String { state["permissionMode"] = mode }
if let path = obj["transcript_path"] as? String { state["transcriptPath"] = path }
if let cwd = obj["cwd"] as? String { state["cwd"] = cwd }

func setWaiting(_ reason: String?) {
    if let reason {
        state["waiting"] = true
        state["reason"] = reason
    } else {
        state["waiting"] = false
        state.removeValue(forKey: "reason")
    }
}

switch event {
case "Notification":
    let type = obj["notification_type"] as? String ?? ""
    let message = obj["message"] as? String ?? "Needs your attention"
    if type == "permission_prompt" || type == "elicitation_dialog"
        || (type.isEmpty && message.lowercased().contains("permission")) {
        setWaiting(message)
    }
case "PreToolUse":
    let tool = obj["tool_name"] as? String ?? ""
    if tool == "AskUserQuestion" {
        let toolInput = obj["tool_input"] as? [String: Any]
        let first = (toolInput?["questions"] as? [[String: Any]])?.first
        setWaiting((first?["question"] as? String).map { "Asks: \($0)" } ?? "Asked you a question")
    } else if tool == "ExitPlanMode" {
        setWaiting("Plan ready for your approval")
    }
case "SessionEnd":
    state["ended"] = true
    setWaiting(nil)
default:
    // SessionStart, UserPromptSubmit, PostToolUse, Stop: whatever it was waiting on is over.
    setWaiting(nil)
}

if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
    try? data.write(to: file, options: .atomic)
}
exit(0)
