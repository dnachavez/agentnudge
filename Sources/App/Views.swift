import AppKit
import SwiftUI

// A small dark visual language: translucent glass surfaces (the macOS menu material),
// hairline borders, one colored light per status, and text. No icons in the content.

enum Theme {
    static let hairline = Color.white.opacity(0.13)
    static let text = Color.white.opacity(0.94)
    static let sub = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.4)
    static let hover = Color.white.opacity(0.08)
    static let chip = Color.white.opacity(0.14)
    static let track = Color.white.opacity(0.1)
    /// Snapshots can't render the material, so they paint this instead.
    static let glassFallback = Color(red: 0.2, green: 0.2, blue: 0.22)

    static let waiting = Color(red: 1.00, green: 0.83, blue: 0.23)
    static let running = Color(red: 0.48, green: 0.64, blue: 0.97)
    static let idle = Color(red: 0.55, green: 0.56, blue: 0.6)
    static let later = Color(red: 0.70, green: 0.57, blue: 0.94)
    static let done = Color(red: 0.4, green: 0.41, blue: 0.44)
    static let danger = Color(red: 1.00, green: 0.5, blue: 0.5)

    static func color(_ b: Bucket) -> Color {
        switch b {
        case .needsYou: return waiting
        case .inProgress: return running
        case .idle: return idle
        case .later: return later
        case .done: return done
        }
    }

    /// Calm under 70 percent, a warning under 90, alarm beyond.
    static func usage(_ percent: Double) -> Color {
        percent >= 90 ? danger : (percent >= 70 ? waiting : text)
    }
}

/// The counts every indicator shows.
struct Tally {
    let needs: Int
    let running: Int
    let idle: Int

    @MainActor init(_ store: SessionStore) {
        needs = store.count(.needsYou)
        running = store.count(.inProgress)
        idle = store.count(.idle)
    }

    var spoken: String {
        "AgentNudge: \(needs) waiting, \(running) running, \(idle) idle"
    }
}

// MARK: Pieces

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True while rendering offscreen, where the glass material can't draw.
    var snapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

/// A shape's hairline edge on the glass the window provides (see `GlassHost`).
struct Surface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.snapshot) private var snapshot

    func body(content: Content) -> some View {
        content
            .background(snapshot ? shape.fill(Theme.glassFallback) : nil)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func surface<S: InsettableShape>(_ shape: S) -> some View { modifier(Surface(shape: shape)) }
}

struct Dot: View {
    let color: Color
    var size: CGFloat = 7
    var glow = false
    var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if pulse && !reduceMotion { PulseRing(color: color, size: size) }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: glow ? color.opacity(0.9) : .clear, radius: glow ? 4 : 0)
        }
        .frame(width: size, height: size)
    }
}

/// A ring that keeps leaving the light and fading, while something needs you.
struct PulseRing: View {
    let color: Color
    let size: CGFloat
    @State private var out = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 1.5)
            .frame(width: size, height: size)
            .scaleEffect(out ? 3 : 1)
            .opacity(out ? 0 : 0.9)
            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: out)
            .onAppear { out = true }
            .allowsHitTesting(false)
    }
}

/// A border that brightens and dims, while something needs you.
struct PulseBorder<S: InsettableShape>: View {
    let shape: S
    let color: Color
    @State private var bright = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        shape
            .strokeBorder(color, lineWidth: 1.5)
            .opacity(reduceMotion ? 0.6 : (bright ? 0.85 : 0.15))
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: bright)
            .onAppear { bright = true }
            .allowsHitTesting(false)
    }
}

struct Divot: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(width: 1, height: 14) }
}

/// The mark's three quarters (see `Mark`), with a gutter that widens as the mark shrinks.
struct Quarters: Shape {
    var gutter: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for quarter in Mark.quarters(in: rect, gutter: gutter) { path.addPath(Path(quarter)) }
        return path
    }
}

/// The mark: three agents and a light in the fourth corner. The light carries the state.
struct MarkView: View {
    var light: Color?
    var size: CGFloat = 16
    var glow = false
    var pulse = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Quarters(gutter: size < 24 ? 8 : 5).fill(Theme.text)
            if let light {
                let r = Mark.light(in: CGRect(x: 0, y: 0, width: size, height: size))
                Dot(color: light, size: r.width, glow: glow, pulse: pulse)
                    .offset(x: r.minX, y: r.minY)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: Indicators

/// The corner tray: a small box on glass. Its border and light pulse while something needs you.
struct TrayView: View {
    @ObservedObject var store: SessionStore
    var onTap: () -> Void
    @State private var hover = false

    static let radius: CGFloat = 7

    var body: some View {
        let t = Tally(store)
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        HStack(spacing: 9) {
            if t.needs > 0 {
                MarkView(light: Theme.waiting, glow: true, pulse: true)
                Text("\(t.needs) waiting").foregroundStyle(Theme.text)
                if t.running > 0 {
                    Divot()
                    Text("\(t.running) running").foregroundStyle(Theme.sub)
                }
            } else if t.running > 0 {
                MarkView(light: Theme.running, glow: true)
                Text("\(t.running) running").foregroundStyle(Theme.text)
            } else if t.idle > 0 {
                MarkView(light: Theme.idle)
                Text("\(t.idle) idle").foregroundStyle(Theme.sub)
            } else {
                MarkView(light: nil)
                Text("All clear").foregroundStyle(Theme.sub)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .monospacedDigit()
        .fixedSize()
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(hover ? Theme.hover : Color.clear)
        .surface(shape)
        .overlay { if t.needs > 0 { PulseBorder(shape: shape, color: Theme.waiting) } }
        .contentShape(shape)
        .onHover { hover = $0 }
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t.spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onTap)
        .fixedSize()
    }
}

/// Wings either side of the notch, in the notch's own black so they read as part of it:
/// what needs you on the left, what is running on the right. The controller sizes each
/// wing to the free menu bar space beside the notch, and a wing with no room is left out,
/// so the wings never cover menu titles or menu bar icons.
struct NotchView: View {
    @ObservedObject var store: SessionStore
    let notchWidth: CGFloat
    let height: CGFloat
    let leftWing: CGFloat
    let rightWing: CGFloat
    var onTap: () -> Void

    /// How wide a wing wants to be; the controller gives it less, or none, when the menu bar is full.
    static let wing: CGFloat = 46

    var body: some View {
        let t = Tally(store)
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if t.needs > 0 {
                    Dot(color: Theme.waiting, size: 7, glow: true, pulse: true)
                    Text("\(t.needs)").foregroundStyle(Theme.text)
                }
            }
            .frame(width: leftWing)
            .clipped()
            Color.black.frame(width: notchWidth)
            HStack(spacing: 6) {
                if t.running > 0 {
                    Dot(color: Theme.running, size: 6)
                    Text("\(t.running)").foregroundStyle(Theme.sub)
                }
            }
            .frame(width: rightWing)
            .clipped()
        }
        .font(.system(size: 12, weight: .semibold))
        .monospacedDigit()
        .frame(height: height)
        .background(NotchShape(radius: min(10, height / 3)).fill(Color.black))
        .overlay(alignment: .bottom) {
            // The notch's lower edge glows while something needs you.
            if t.needs > 0 { NotchGlow(width: notchWidth) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t.spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onTap)
    }
}

struct NotchGlow: View {
    let width: CGFloat
    @State private var bright = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(Theme.waiting)
            .frame(width: width * 0.5, height: 1.5)
            .shadow(color: Theme.waiting, radius: 3)
            .opacity(reduceMotion ? 0.7 : (bright ? 0.9 : 0.2))
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: bright)
            .onAppear { bright = true }
            .padding(.bottom, 1)
            .allowsHitTesting(false)
    }
}

struct NotchShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: Session list

struct ListView: View {
    @ObservedObject var store: SessionStore
    @State private var tab: Bucket
    @State private var launching: Bool
    @Namespace private var underline
    var onOpen: (AgentThread) -> Void
    var onLaunched: () -> Void
    private let snapshot: Bool

    static let width: CGFloat = 400
    static let radius: CGFloat = 14
    private let height: CGFloat

    /// Sized once when the list opens, to fit its fullest tab, so switching tabs never
    /// resizes the window. Longer lists scroll.
    @MainActor static func height(for store: SessionStore) -> CGFloat {
        let fullest = Bucket.allCases.map { b in
            store.threads(in: b).reduce(CGFloat(0)) { sum, t in
                var row: CGFloat = 58
                if t.waitingReason != nil { row += 18 }
                if t.summary != nil { row += 32 }
                if !t.subagents.isEmpty { row += 16 }
                return sum + row
            }
        }.max() ?? 0
        let footer: CGFloat = store.usage == nil ? 0 : 38
        return min(max(46 + fullest + 16, 340), 500) + footer
    }

    init(store: SessionStore, onOpen: @escaping (AgentThread) -> Void, onLaunched: @escaping () -> Void = {},
         initialTab: Bucket? = nil, launching: Bool = false) {
        self.store = store
        self.onOpen = onOpen
        self.onLaunched = onLaunched
        _launching = State(initialValue: launching)
        let start: Bucket
        if let initialTab {
            start = initialTab
        } else {
            start = store.count(.needsYou) == 0 && store.count(.inProgress) > 0 ? .inProgress : .needsYou
        }
        _tab = State(initialValue: start)
        snapshot = initialTab != nil
        height = Self.height(for: store)
    }

    var body: some View {
        VStack(spacing: 0) {
            if launching {
                LauncherView(store: store, onBack: { launching = false }, onLaunched: onLaunched)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                tabs
                Rectangle().fill(Theme.hairline).frame(height: 1)
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            if let usage = store.usage {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                UsageStrip(usage: usage).padding(.horizontal, 16).frame(height: 37)
            }
        }
        .frame(width: Self.width, height: height)
        .surface(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))

    }

    private var tabs: some View {
        HStack(spacing: 15) {
            ForEach(Bucket.allCases) { b in
                let n = store.count(b)
                let on = tab == b
                VStack(spacing: 9) {
                    HStack(spacing: 5) {
                        Text(b.rawValue)
                        if n > 0 { Text("\(n)").foregroundStyle(on ? Theme.color(b) : Theme.faint) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(on ? Theme.text : Theme.sub)
                    ZStack {
                        if on {
                            Capsule().fill(Theme.text).frame(height: 1.5)
                                .matchedGeometryEffect(id: "underline", in: underline)
                        } else {
                            Color.clear.frame(height: 1.5)
                        }
                    }
                }
                .fixedSize()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.18)) { tab = b }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
            TextAction(title: "+ New") { launching = true }
                .fixedSize()
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
    }

    @ViewBuilder private var content: some View {
        let items = store.threads(in: tab)
        if items.isEmpty {
            Text(emptyText)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if snapshot {
            // ImageRenderer-style offscreen capture draws nothing inside a ScrollView.
            rows(items)
        } else {
            ScrollView(showsIndicators: false) { rows(items) }
        }
    }

    private func rows(_ items: [AgentThread]) -> some View {
        LazyVStack(spacing: 2) {
            ForEach(items) { t in
                ThreadRow(thread: t, store: store, onOpen: onOpen)
            }
        }
        .padding(8)
    }

    private var emptyText: String {
        switch tab {
        case .needsYou: return "Nothing needs you"
        case .inProgress: return "Nothing running"
        case .idle: return "Nothing idle"
        case .later: return "Nothing put off"
        case .done: return "Nothing done yet"
        }
    }
}

struct ThreadRow: View {
    let thread: AgentThread
    @ObservedObject var store: SessionStore
    var onOpen: (AgentThread) -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Dot(color: thread.status == "ended" ? Theme.done : Theme.color(thread.bucket),
                glow: thread.bucket == .needsYou)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(thread.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if hover {
                        actions
                    } else {
                        Text(SessionStore.duration(Date().timeIntervalSince(thread.lastActivity)))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.faint)
                    }
                }
                if let reason = thread.waitingReason {
                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundStyle(thread.bucket == .needsYou ? Theme.waiting : Theme.sub)
                        .lineLimit(2)
                }
                if let summary = thread.summary {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.sub)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                meta
                if !thread.subagents.isEmpty {
                    Text("\(thread.subagents.count) agent\(thread.subagents.count == 1 ? "" : "s") · "
                         + thread.subagents.map(\.description).joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.running.opacity(0.85))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? Theme.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onOpen(thread) }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Later") { store.markLater(thread) }
        .accessibilityAction(named: "Done") { store.markDone(thread) }
    }

    /// project · branch · mode, one quiet monospaced line.
    private var meta: some View {
        let dot = Text(" · ").foregroundColor(Theme.faint.opacity(0.6))
        var line = thread.agent == .codex ? Text("codex").foregroundColor(Theme.later) + dot + Text(thread.project) : Text(thread.project)
        if let branch = thread.branch { line = line + dot + Text(branch) }
        if let mode = thread.mode {
            let name = Self.modeName(mode)
            line = line + dot + Text(name).foregroundColor(mode == "bypassPermissions" ? Theme.danger.opacity(0.85) : Theme.faint)
        }
        if let context = thread.context { line = line + dot + Text("ctx \(Int(context.rounded()))%").foregroundColor(context >= 80 ? Theme.waiting : Theme.faint) }
        if thread.kind == "bg" { line = line + dot + Text("background") }
        return line
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(Theme.faint)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 10) {
            switch thread.bucket {
            case .later:
                TextAction(title: "Restore") { store.restore(thread) }
                TextAction(title: "Done") { store.markDone(thread) }
            case .done:
                if thread.status != "ended" { TextAction(title: "Restore") { store.restore(thread) } }
            default:
                TextAction(title: "Later") { store.markLater(thread) }
                TextAction(title: "Done") { store.markDone(thread) }
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Open") { onOpen(thread) }.disabled(thread.pid == nil)
        Divider()
        Button("Later") { store.markLater(thread) }
        Button("Done") { store.markDone(thread) }
        Button("Restore") { store.restore(thread) }.disabled(thread.bucket != .later && thread.bucket != .done)
        Divider()
        Button("Copy Folder Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(thread.cwd, forType: .string)
        }
    }

    static func modeName(_ mode: String) -> String {
        switch mode {
        case "bypassPermissions": return "bypass"
        case "acceptEdits": return "accept edits"
        case "default": return "ask"
        default: return mode
        }
    }
}

struct TextAction: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(hover ? Theme.text : Theme.sub)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: Launcher

/// Opens a new terminal tab in a workspace, running Claude, a branch session, Codex, or a plain shell.
struct LauncherView: View {
    @ObservedObject var store: SessionStore
    var onBack: () -> Void
    var onLaunched: () -> Void
    @State private var folder: String?
    @State private var kind: SessionStore.Launch = .claude
    @State private var branch = ""
    @FocusState private var branchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextAction(title: "‹ Sessions", action: onBack)
                Spacer()
                Text("NEW SESSION").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.faint)
            }

            label("Workspace")
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(store.state.workspaces, id: \.self) { path in
                        workspaceRow(path)
                    }
                    HStack {
                        TextAction(title: "+ Add folder…", action: addFolder)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
            }
            .frame(maxHeight: 150)

            label("Run")
            Chips(options: SessionStore.Launch.allCases.map { ($0.rawValue, $0) }, selection: kind) { picked in
                kind = picked
                if picked == .branch { branchFocused = true }
            }

            if kind == .branch {
                TextField("", text: $branch, prompt: Text("branch name").foregroundColor(Theme.faint))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))
                    .focused($branchFocused)
                    .onSubmit(launch)
            }

            Spacer(minLength: 0)

            HStack(alignment: .center) {
                Text(preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("Open")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(canLaunch ? Color.black : Theme.faint)
                    .padding(.horizontal, 16)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(canLaunch ? Theme.text : Color.white.opacity(0.08)))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: launch)
                    .accessibilityAddTraits(.isButton)
            }
        }
        .padding(16)
        .onAppear {
            folder = folder ?? store.state.workspaces.first
            if branch.isEmpty, let clip = NSPasteboard.general.string(forType: .string),
               let name = SessionStore.branchName(clip), name.contains("-") || name.contains("/") {
                branch = name
            }
        }
    }

    private var canLaunch: Bool {
        folder != nil && (kind != .branch || SessionStore.branchName(branch) != nil)
    }

    private var preview: String {
        guard let folder else { return "Pick a workspace" }
        let command = store.command(for: kind, branch: branch) ?? (kind == .branch ? "type a branch name" : "shell")
        return "\(SessionStore.projectName(folder)) $ \(command)"
    }

    private func launch() {
        guard canLaunch, let folder else { return }
        store.launch(kind, in: folder, branch: branch)
        onLaunched()
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.faint)
    }

    private func workspaceRow(_ path: String) -> some View {
        let on = path == folder
        return HStack(spacing: 10) {
            Circle().fill(on ? Theme.text : Color.clear)
                .overlay(Circle().strokeBorder(on ? Color.clear : Theme.faint, lineWidth: 1))
                .frame(width: 7, height: 7)
            Text(SessionStore.projectName(path)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
            Spacer()
            Text((path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Theme.hover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { folder = path }
        .contextMenu {
            Button("Remove from List") {
                store.removeWorkspace(path)
                if folder == path { folder = store.state.workspaces.first }
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            store.addWorkspace(url.path)
            folder = url.path
        }
    }
}

// MARK: Usage

/// Plan usage from the status line: the 5-hour and 7-day windows, each with a thin meter
/// and when it resets.
struct UsageStrip: View {
    let usage: Usage

    var body: some View {
        HStack(spacing: 18) {
            if let five = usage.fiveHour { Meter(label: "5h", percent: five, reset: usage.fiveHourReset, width: 40) }
            if let seven = usage.sevenDay { Meter(label: "7d", percent: seven, reset: usage.sevenDayReset, width: 40) }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct Meter: View {
    let label: String
    let percent: Double
    let reset: Date?
    var width: CGFloat = 54

    var body: some View {
        HStack(spacing: 7) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.faint)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Theme.usage(percent)).frame(width: max(2, width * min(percent, 100) / 100))
            }
            .frame(width: width, height: 4)
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            if let reset, reset > Date() {
                Text("resets \(SessionStore.duration(reset.timeIntervalSinceNow))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .help("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .fixedSize()
    }
}

// MARK: Settings (the menu bar dropdown)

struct SettingsPanel: View {
    @ObservedObject var store: SessionStore
    var onQuit: () -> Void
    @State private var openAtLogin = LoginItem.enabled

    static let radius: CGFloat = 14

    var body: some View {
        let t = Tally(store)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    MarkView(light: Theme.waiting, size: 16).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text("AgentNudge").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                }
                Spacer()
                Text("\(t.needs) waiting · \(t.running) running")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.faint)
            }

            if let usage = store.usage {
                field("Usage") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let five = usage.fiveHour { Meter(label: "5h", percent: five, reset: usage.fiveHourReset) }
                        if let seven = usage.sevenDay { Meter(label: "7d", percent: seven, reset: usage.sevenDayReset) }
                    }
                }
            }

            field("Display") {
                Chips(options: Placement.allCases.map { ($0.label, $0) }, selection: store.state.placement) { store.setPlacement($0) }
            }
            if store.state.placement == .corner {
                field("Corner") {
                    CornerPicker(selection: store.state.corner) { store.setCorner($0) }
                }
            }
            field("Move to idle after") {
                Chips(options: PersistedState.idleChoices.map { ($0 < 60 ? "\($0)m" : "\($0 / 60)h", $0) },
                      selection: store.state.idleMinutes) { store.setIdleMinutes($0) }
            }

            field("New session runs") {
                VStack(spacing: 6) {
                    CommandField(title: "Claude", text: store.state.claudeCommand) { store.setCommand(.claude, $0) }
                    CommandField(title: "Branch", text: store.state.branchCommand) { store.setCommand(.branch, $0) }
                    CommandField(title: "Codex", text: store.state.codexCommand) { store.setCommand(.codex, $0) }
                }
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(spacing: 12) {
                SwitchRow(title: "Hide when a terminal is focused", on: store.state.hideInTerminal) { store.setHideInTerminal($0) }
                SwitchRow(title: "Open at login", on: openAtLogin) { on in
                    LoginItem.set(on)
                    openAtLogin = LoginItem.enabled
                }
                HStack {
                    Text("Claude Code hooks").foregroundStyle(Theme.sub)
                    Spacer()
                    Text(store.hooksInstalled ? "Installed" : "Not installed")
                        .foregroundStyle(store.hooksInstalled ? Theme.text : Theme.faint)
                }
                .font(.system(size: 12))
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                TextAction(title: "Data folder") { NSWorkspace.shared.open(Paths.data) }
                Spacer()
                TextAction(title: "Quit", action: onQuit)
            }
        }
        .padding(16)
        .frame(width: 296)
        .surface(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .fixedSize()
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.faint)
            content()
        }
    }
}

/// One launch command, edited in place. `{branch}` stands for the branch name.
struct CommandField: View {
    let title: String
    let set: (String) -> Void
    @State private var value: String

    init(title: String, text: String, set: @escaping (String) -> Void) {
        self.title = title
        self.set = set
        _value = State(initialValue: text)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.sub).frame(width: 48, alignment: .leading)
            TextField("", text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
                .onChange(of: value) { _, new in set(new) }
        }
    }
}

/// A row of text options on one track, the selected one lifted.
struct Chips<T: Hashable>: View {
    let options: [(String, T)]
    let selection: T
    let pick: (T) -> Void
    @Namespace private var lift

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.1) { title, value in
                let on = value == selection
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(on ? Theme.text : Theme.sub)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.chip)
                                .matchedGeometryEffect(id: "lift", in: lift)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.18)) { pick(value) } }
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

/// Four small screens, each with a dot in its corner.
struct CornerPicker: View {
    let selection: Corner
    let pick: (Corner) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach([Corner.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { c in
                let on = c == selection
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(on ? Theme.text.opacity(0.7) : Theme.hairline, lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? Theme.chip : Color.white.opacity(0.04)))
                    .frame(width: 40, height: 26)
                    .overlay(alignment: alignment(c)) {
                        Capsule().fill(on ? Theme.text : Theme.faint).frame(width: 10, height: 4).padding(4)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { pick(c) }
                    .accessibilityLabel(c.label)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private func alignment(_ c: Corner) -> Alignment {
        switch c {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}

struct SwitchRow: View {
    let title: String
    let on: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.text)
            Spacer()
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Theme.text : Color.white.opacity(0.14)).frame(width: 28, height: 16)
                Circle().fill(on ? Color(red: 0.12, green: 0.12, blue: 0.13) : Color.white.opacity(0.75)).frame(width: 12, height: 12).padding(2)
            }
            .frame(width: 28, height: 16)
            .animation(.snappy(duration: 0.15), value: on)
        }
        .contentShape(Rectangle())
        .onTapGesture { set(!on) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}
