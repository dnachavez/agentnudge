import AppKit
import Combine
import UniformTypeIdentifiers
import UserNotifications

enum NotifyKind {
    case needsInput, finished

    var title: String {
        switch self {
        case .needsInput: return "Needs input"
        case .finished: return "Turn finished"
        }
    }

    var defaultSound: String {
        switch self {
        case .needsInput: return "Funk"
        case .finished: return "Glass"
        }
    }

    func sound(in state: PersistedState) -> String {
        switch self {
        case .needsInput: return state.needsInputSound
        case .finished: return state.finishedSound
        }
    }
}

/// Sounds are played with NSSound rather than as the notification's own sound: a custom
/// UNNotificationSound can't be an mp3, has been reported ignored on macOS 26, and would tie
/// the Sounds switch to notification permission.
@MainActor
enum Sounds {
    static let system = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    private static let extensions: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "caf"]
    private static var playing: NSSound?

    static func isCustom(_ value: String) -> Bool { !value.isEmpty && !system.contains(value) }

    static func isMissing(_ value: String) -> Bool {
        isCustom(value) && !FileManager.default.fileExists(atPath: Paths.sounds.appendingPathComponent(value).path)
    }

    static func customFiles() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.sounds.path)) ?? []
        return files.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
    }

    static func play(_ value: String, fallback: String) {
        guard !value.isEmpty else { return }
        let sound: NSSound?
        if isMissing(value) {
            sound = NSSound(named: fallback)
        } else if isCustom(value) {
            sound = NSSound(contentsOf: Paths.sounds.appendingPathComponent(value), byReference: true)
        } else {
            sound = NSSound(named: value)
        }
        playing?.stop()
        playing = sound
        sound?.play()
    }

    /// Asks for an audio file, copies it into ~/.agentnudge/sounds, and passes the stored name on.
    static func importFile(then select: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Choose"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let fm = FileManager.default
        let ext = url.pathExtension
        // A name without an extension could be taken for a system sound.
        guard !ext.isEmpty else { return }
        try? fm.createDirectory(at: Paths.sounds, withIntermediateDirectories: true)

        let base = url.deletingPathExtension().lastPathComponent
        var name = "\(base).\(ext)"
        var n = 2
        while fm.fileExists(atPath: Paths.sounds.appendingPathComponent(name).path) {
            name = "\(base)-\(n).\(ext)"
            n += 1
        }
        let dest = Paths.sounds.appendingPathComponent(name)
        guard (try? fm.copyItem(at: url, to: dest)) != nil else { return }
        guard NSSound(contentsOf: dest, byReference: true) != nil else {
            try? fm.removeItem(at: dest)
            return
        }
        select(name)
    }
}

/// Posts a banner and plays a sound when a session starts asking for you or finishes a turn.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private struct Mark {
        var bucket: Bucket
        var status: String
        /// Set once the thread is seen working or waiting, and spent the first time it is seen
        /// idle. Only an armed thread's idle is a finished turn: `lastActivity` alone never
        /// fires, because the hook rewrites it for `idle_prompt` about a minute after a turn,
        /// which pulls a Later or Done thread back into Needs you with no new work.
        var armed: Bool
    }

    private weak var store: SessionStore?
    private var open: (String) -> Void = { _ in }
    private var marks: [String: Mark] = [:]
    private var seeded = false
    private var pendingOpen: String?
    private var subscriptions: Set<AnyCancellable> = []

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func attach(store: SessionStore, open: @escaping (String) -> Void) {
        self.store = store
        self.open = open
        refreshAuthorization()
        // The first scan publishes its threads before `scanned` flips, so diffing starts at the seed.
        store.$scanned.first { $0 }.sink { [weak self] _ in self?.seed() }.store(in: &subscriptions)
        store.$threads.sink { [weak self] threads in self?.diff(threads) }.store(in: &subscriptions)
        store.$state.map(\.notifications).removeDuplicates().dropFirst().sink { [weak self] on in
            if on { self?.requestAuthorization() }
        }.store(in: &subscriptions)
    }

    func refreshAuthorization() {
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            store?.setNotificationsDenied(settings.authorizationStatus == .denied)
        }
    }

    private func requestAuthorization() {
        Task { @MainActor in _ = await authorized() }
    }

    /// Asks only while the answer is still open, so nothing prompts at launch, where it
    /// would land on the first-run Settings sheet.
    private func authorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert])
            status = await center.notificationSettings().authorizationStatus
        }
        store?.setNotificationsDenied(status == .denied)
        return status == .authorized || status == .provisional
    }

    private func seed() {
        guard let store else { return }
        let threads = store.threads
        for t in threads { marks[t.id] = Mark(bucket: t.bucket, status: t.status, armed: Self.arms(t.status)) }
        seeded = true
        let current = Set(threads.filter { $0.bucket == .needsYou }.map(\.id))
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let stale = await center.deliveredNotifications().map(\.request.identifier).filter { !current.contains($0) }
            center.removeDeliveredNotifications(withIdentifiers: stale)
        }
        if let id = pendingOpen {
            pendingOpen = nil
            open(id)
        }
    }

    private static func arms(_ status: String) -> Bool {
        status == "busy" || status == "shell" || status == "waiting"
    }

    private func diff(_ threads: [AgentThread]) {
        guard seeded else { return }
        var events: [(AgentThread, NotifyKind)] = []
        var left: [String] = []
        var next: [String: Mark] = [:]
        for t in threads {
            let old = marks[t.id]
            var armed = old?.armed ?? false
            if Self.arms(t.status) {
                armed = true
            } else if t.status == "idle" || t.status == "ended" {
                armed = false
            }
            next[t.id] = Mark(bucket: t.bucket, status: t.status, armed: armed)

            if t.bucket == .needsYou {
                if t.status == "waiting", old?.status != "waiting" {
                    events.append((t, .needsInput))
                } else if t.status == "idle", old?.armed == true, !t.statusGuessed {
                    events.append((t, .finished))
                }
            } else if old?.bucket == .needsYou {
                left.append(t.id)
            }
        }
        left += marks.keys.filter { next[$0] == nil && marks[$0]?.bucket == .needsYou }
        marks = next
        if !left.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: left) }
        if !events.isEmpty { deliver(events) }
    }

    private func deliver(_ events: [(AgentThread, NotifyKind)]) {
        guard let state = store?.state else { return }
        if state.sounds {
            let kind: NotifyKind = events.contains { $0.1 == .needsInput } ? .needsInput : .finished
            Sounds.play(kind.sound(in: state), fallback: kind.defaultSound)
        }
        guard state.notifications else { return }
        Task { @MainActor in
            guard await authorized() else { return }
            for (thread, kind) in events {
                try? await UNUserNotificationCenter.current().add(Self.request(for: thread, kind: kind))
            }
        }
    }

    private static func request(for t: AgentThread, kind: NotifyKind) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = t.title
        content.subtitle = [t.project, t.branch].compactMap { $0 }.joined(separator: " · ")
        let body: String
        switch kind {
        case .needsInput: body = t.waitingReason ?? "Needs your input"
        case .finished: body = t.summary ?? "Finished its turn"
        }
        content.body = body.count > 200 ? String(body.prefix(200)) + "…" : body
        content.userInfo = ["id": t.id]
        content.threadIdentifier = t.project
        content.sound = nil
        return UNNotificationRequest(identifier: t.id, content: content, trigger: nil)
    }

    private func clicked(_ id: String) {
        if seeded { open(id) } else { pendingOpen = id }
    }

    // The center calls these off the main actor. `UNNotificationResponse` isn't Sendable,
    // so the id is pulled out before hopping over.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["id"] as? String else { return }
        await MainActor.run { clicked(id) }
    }
}
