// SwiftUI popover: gauges, load trend, suspect cards and usage bars.
import AppKit
import Charts
import ServiceManagement
import SwiftUI

// MARK: - View model

struct Sample: Identifiable {
    let id: Int
    let load: Double
}

struct GroupStat: Identifiable {
    let name: String
    let kb: Int
    let pids: [Int32]
    let icon: String?
    var id: String { name }
}

enum Category: String, CaseIterable, Identifiable {
    case claude, dev, monitors, mcp, sim, chrome
    var id: String { rawValue }
}

final class Model: ObservableObject {
    @Published var stats = Stats.read()
    @Published var history: [Sample] = []
    @Published var snap: Snapshot?
    @Published var sus: Suspects?
    @Published var groups: [GroupStat] = []
    @Published var topCPU: [Proc] = []
    @Published var loading = false
    @Published var updated = Date()
    @Published var selected: Category? = .claude
    @Published var usageTab = 0
    /// Headless rendering: avoid AppKit-backed views that ImageRenderer can't draw.
    var snapshotMode = false
    weak var app: AppDelegate?
    private var counter = 0
    private var syncingLogin = false

    @Published var showLoad = UserDefaults.standard.object(forKey: "showLoad") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showLoad, forKey: "showLoad"); app?.tick() }
    }
    @Published var notify = UserDefaults.standard.object(forKey: "notifyCritical") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notify, forKey: "notifyCritical") }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard !syncingLogin, oldValue != launchAtLogin else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                syncingLogin = true
                launchAtLogin = SMAppService.mainApp.status == .enabled
                syncingLogin = false
            }
        }
    }

    init() {
        // Seed the chart with the 15 → 5 → 1 minute averages so it isn't empty at launch.
        let s = stats
        let anchors = [s.load[2], s.load[1], s.load[0]]
        for i in 0..<24 {
            let t = Double(i) / 23 * 2
            let lo = min(Int(t), 1)
            let v = anchors[lo] + (anchors[lo + 1] - anchors[lo]) * (t - Double(lo))
            history.append(Sample(id: i, load: v))
        }
        counter = 24
    }

    func tick() {
        stats = Stats.read()
        history.append(Sample(id: counter, load: stats.load[0]))
        counter += 1
        if history.count > 120 { history.removeFirst(history.count - 120) }
    }

    /// Heavy scan (ps + lsof), done off the main thread.
    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Model.scan()
            DispatchQueue.main.async { self.apply(r) }
        }
    }

    func refreshSync() { apply(Model.scan()) }

    private static func scan() -> (Snapshot, Suspects, [GroupStat], [Proc]) {
        let snap = Snapshot()
        let sus = Suspects(snap)
        var g: [String: (kb: Int, pids: [Int32], icon: String?)] = [:]
        for p in snap.procs.values {
            var e = g[p.group] ?? (0, [], nil)
            e.kb += p.rssKB
            e.pids.append(p.pid)
            if e.icon == nil { e.icon = p.bundlePath }
            g[p.group] = e
        }
        let groups = g.map { GroupStat(name: $0.key, kb: $0.value.kb, pids: $0.value.pids, icon: $0.value.icon) }
            .sorted { $0.kb > $1.kb }
        let me = getpid()
        let top = snap.procs.values.filter { $0.pid != me && $0.name != "ps" }.sorted { $0.cpu > $1.cpu }
        return (snap, sus, Array(groups.prefix(8)), Array(top.prefix(8)))
    }

    private func apply(_ r: (Snapshot, Suspects, [GroupStat], [Proc])) {
        snap = r.0; sus = r.1; groups = r.2; topCPU = r.3
        stats = Stats.read()
        updated = Date()
        loading = false
    }

    var safeTargets: [Target] {
        guard let s = sus else { return [] }
        return s.monitors + s.detachedClaude + s.orphanMCP
    }
}

// MARK: - Styling helpers

extension Severity {
    var color: Color { [Color.green, .orange, .red][rawValue] }
}

func tone(_ f: Double, warn: Double, crit: Double) -> Color {
    f >= crit ? .red : f >= warn ? .orange : .green
}

func shortGB(_ bytes: UInt64) -> String {
    let g = Double(bytes) / 1_073_741_824
    return g >= 10 ? String(format: "%.0f", g) : String(format: "%.1f", g)
}

func appIcon(_ path: String?) -> NSImage? {
    guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
    return NSWorkspace.shared.icon(forFile: path)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(1)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: Model

    @State private var contentHeight: CGFloat = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(model: model)
            if model.snapshotMode {
                sections
            } else {
                // Header and footer stay pinned; the middle scrolls when the
                // popover would otherwise be taller than the screen.
                ScrollView(.vertical) {
                    sections.background(GeometryReader { g in
                        Color.clear.preference(key: HeightKey.self, value: g.size.height)
                    })
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(contentHeight, maxScrollHeight))
                .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
            }
            Footer(model: model)
        }
        .padding(16)
        .frame(width: 420)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 12) {
            Gauges(model: model)
            LoadChart(model: model)
            RelieveButton(model: model)
            CategoryGrid(model: model)
            if let c = model.selected, model.sus != nil {
                DetailList(model: model, category: c)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            UsageSection(model: model)
        }
    }

    /// Screen height minus menu bar, popover arrow, header, footer and padding.
    private var maxScrollHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(300, screen - 150)
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Header

struct Header: View {
    @ObservedObject var model: Model
    var body: some View {
        let sev = model.stats.severity
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [sev.color, sev.color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .shadow(color: sev.color.opacity(0.4), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("Pressure Valve").font(.system(size: 15, weight: .semibold))
                Text("\((model.snap?.total ?? model.snap?.procs.count ?? 0).formatted()) processes · \(model.stats.cores) cores")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(sev.label.uppercased())
                .font(.system(size: 10, weight: .heavy)).tracking(0.8)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(sev.color.gradient))
                .foregroundStyle(.white)
            Button { model.refresh() } label: {
                if model.loading {
                    ProgressView().controlSize(.small).frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)).frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Rescan processes")
        }
    }
}

// MARK: - Gauges

struct Ring: View {
    let fraction: Double
    let value: String
    let unit: String
    let label: String
    let sub: String
    let color: Color

    var body: some View {
        let f = max(0.015, min(fraction, 1))
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(color.opacity(0.14), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: f)
                    .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * f)),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.35), radius: 4)
                    .animation(.easeOut(duration: 0.7), value: f)
                VStack(spacing: -1) {
                    Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(unit).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)
            VStack(spacing: 0) {
                Text(label).font(.system(size: 11, weight: .semibold))
                Text(sub).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct Gauges: View {
    @ObservedObject var model: Model
    var body: some View {
        let s = model.stats
        let ratio = s.load[0] / Double(max(s.cores, 1))
        let memF = Double(s.memUsed) / Double(max(s.memTotal, 1))
        let swapF = s.swapTotal > 0 ? Double(s.swapUsed) / Double(s.swapTotal) : 0
        let swapVsRAM = Double(s.swapUsed) / Double(max(s.memTotal, 1))
        Card {
            HStack(spacing: 0) {
                Ring(fraction: ratio / 6, value: "\(Int(s.load[0].rounded()))", unit: String(format: "%.1f×", ratio),
                     label: "Load", sub: "\(s.cores) cores", color: tone(ratio, warn: 2, crit: 5))
                Ring(fraction: memF, value: "\(Int((memF * 100).rounded()))", unit: "%",
                     label: "Memory", sub: "\(shortGB(s.memUsed)) of \(shortGB(s.memTotal)) GB",
                     color: s.pressure >= 4 ? .red : s.pressure == 2 ? .orange : tone(memF, warn: 0.85, crit: 0.95))
                Ring(fraction: swapF, value: shortGB(s.swapUsed), unit: "GB",
                     label: "Swap", sub: "of \(shortGB(s.swapTotal)) GB", color: tone(swapVsRAM, warn: 0.1, crit: 0.3))
            }
        }
    }
}

// MARK: - Load chart

struct LoadChart: View {
    @ObservedObject var model: Model
    var body: some View {
        let s = model.stats
        let color = tone(s.load[0] / Double(max(s.cores, 1)), warn: 2, crit: 5)
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionTitle(text: "Load trend")
                    Spacer()
                    Text(String(format: "15m %.0f  ·  5m %.0f  ·  1m %.0f", s.load[2], s.load[1], s.load[0]))
                        .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(model.history) { p in
                        AreaMark(x: .value("t", p.id), y: .value("load", p.load))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("t", p.id), y: .value("load", p.load))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .interpolationMethod(.catmullRom)
                    }
                    RuleMark(y: .value("cores", Double(s.cores)))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("\(s.cores) cores").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel().font(.system(size: 9))
                    }
                }
                .frame(height: 74)
            }
        }
    }
}

// MARK: - Relieve

struct RelieveButton: View {
    @ObservedObject var model: Model
    @State private var hover = false
    var body: some View {
        let targets = model.safeTargets
        let empty = targets.isEmpty
        let colors: [Color] = empty ? [.green, .mint] : [Color(red: 1, green: 0.27, blue: 0.42), .orange]
        Button {
            model.app?.confirmAndStop(targets, title: "Relieve pressure?",
                intro: "Stops monitoring tools that keep sysmond busy, Claude Code sessions with no terminal attached, and MCP servers whose parent already exited.")
        } label: {
            HStack(spacing: 12) {
                Image(systemName: empty ? "checkmark.seal.fill" : "wind")
                    .font(.system(size: 20, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(empty ? "Nothing idle to clean up" : "Relieve pressure").font(.system(size: 14, weight: .bold))
                    Text(empty ? "Use the cards below for heavier fixes"
                               : "\(targets.count) idle items · frees about \(mem(sum(targets)))")
                        .font(.system(size: 11)).opacity(0.9)
                }
                Spacer()
                if !empty { Image(systemName: "arrow.right.circle.fill").font(.system(size: 20)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)))
            .shadow(color: colors[0].opacity(hover ? 0.5 : 0.3), radius: hover ? 10 : 6, y: 3)
            .scaleEffect(hover && !empty ? 1.01 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(empty)
        .onHover { hover = $0 }
    }
}

// MARK: - Category cards

struct CategoryInfo {
    let icon: String
    let title: String
    let tint: Color
    let count: Int
    let kb: Int
}

func categories(_ s: Suspects) -> [(Category, CategoryInfo)] {
    var out: [(Category, CategoryInfo)] = [
        (.claude, CategoryInfo(icon: "sparkles", title: "Claude sessions", tint: .orange, count: s.claude.count, kb: sum(s.claude))),
        (.dev, CategoryInfo(icon: "hammer.fill", title: "Dev servers", tint: .blue,
                            count: s.devServers.count, kb: sum(s.devServers.map(\.t)))),
        (.monitors, CategoryInfo(icon: "waveform.path.ecg", title: "Monitors", tint: .purple, count: s.monitors.count, kb: sum(s.monitors))),
        (.mcp, CategoryInfo(icon: "puzzlepiece.extension.fill", title: "Orphan MCP", tint: .teal, count: s.orphanMCP.count, kb: sum(s.orphanMCP))),
    ]
    if s.simBooted { out.append((.sim, CategoryInfo(icon: "iphone", title: "Simulators", tint: .indigo, count: 1, kb: s.simRSS))) }
    if s.chromeRSS > 0 { out.append((.chrome, CategoryInfo(icon: "globe", title: "Chrome", tint: .yellow, count: 1, kb: s.chromeRSS))) }
    return out
}

struct CategoryGrid: View {
    @ObservedObject var model: Model
    var body: some View {
        if let s = model.sus {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(categories(s), id: \.0) { c, info in
                    CategoryCard(info: info, selected: model.selected == c) {
                        withAnimation(.snappy(duration: 0.25)) { model.selected = model.selected == c ? nil : c }
                    }
                }
            }
        } else {
            HStack { Spacer(); ProgressView().controlSize(.small); Text("Scanning processes…").font(.caption); Spacer() }
                .padding(.vertical, 20)
        }
    }
}

struct CategoryCard: View {
    let info: CategoryInfo
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: info.icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(info.tint.gradient))
                VStack(alignment: .leading, spacing: 0) {
                    Text(info.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Text(info.count == 0 ? "—" : mem(info.kb))
                        .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                Spacer(minLength: 0)
                if info.count > 0 {
                    Text("\(info.count)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(info.tint.opacity(0.2)))
                        .foregroundStyle(info.tint)
                }
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? info.tint.opacity(0.16) : Color.primary.opacity(hover ? 0.08 : 0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? info.tint.opacity(0.7) : Color.primary.opacity(0.06), lineWidth: selected ? 1.5 : 1))
            .opacity(info.count == 0 ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Detail list for the selected card

struct DetailList: View {
    @ObservedObject var model: Model
    let category: Category

    var body: some View {
        if let s = model.sus, let snap = model.snap,
           let info = categories(s).first(where: { $0.0 == category })?.1 {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionTitle(text: info.title)
                        Spacer()
                        bulkAction(s, info)
                    }
                    content(s, snap, info)
                }
            }
        }
    }

    @ViewBuilder
    func bulkAction(_ s: Suspects, _ info: CategoryInfo) -> some View {
        switch category {
        case .claude where !s.detachedClaude.isEmpty:
            PillButton(title: "Stop \(s.detachedClaude.count) detached", tint: info.tint) {
                model.app?.confirmAndStop(s.detachedClaude, title: "Stop detached Claude Code sessions?",
                    intro: "These sessions run under tmux or have no terminal, so nobody is typing into them. Their MCP servers stop too.")
            }
        case .dev where !s.staleDev.isEmpty:
            PillButton(title: "Stop \(s.staleDev.count) older than 12h", tint: info.tint) {
                model.app?.confirmAndStop(s.staleDev, title: "Stop dev servers older than 12 hours?", intro: "")
            }
        case .monitors where !s.monitors.isEmpty:
            PillButton(title: "Quit all", tint: info.tint) {
                model.app?.confirmAndStop(s.monitors, title: "Quit monitoring tools?",
                    intro: "Activity Monitor and CleanMyMac's health monitor poll sysmond constantly. CleanMyMac may relaunch its agent unless you turn it off in its settings.")
            }
        case .mcp where !s.orphanMCP.isEmpty:
            PillButton(title: "Kill all", tint: info.tint) {
                model.app?.confirmAndStop(s.orphanMCP, title: "Kill orphaned MCP servers?",
                    intro: "Their Claude or editor session already exited, so nothing can talk to them.")
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    func content(_ s: Suspects, _ snap: Snapshot, _ info: CategoryInfo) -> some View {
        switch category {
        case .sim:
            BigAction(text: "A simulator is booted. Its runtime, render server and apps add up to about \(mem(s.simRSS)) of resident memory.",
                      button: "Shut down all simulators", icon: "power", tint: info.tint) { model.app?.shutdownSimulators(s.simRSS) }
        case .chrome:
            BigAction(text: "Chrome is using about \(mem(s.chromeRSS)) across its helper processes. A restart reloads tabs lazily.",
                      button: "Restart Chrome", icon: "arrow.triangle.2.circlepath", tint: info.tint) { model.app?.restartChrome() }
        default:
            let rows: [Target] = {
                switch category {
                case .claude: return s.claude
                case .dev: return s.devServers.map(\.t)
                case .monitors: return s.monitors
                default: return s.orphanMCP
                }
            }()
            if rows.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Nothing here right now").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                let list = VStack(spacing: 5) {
                    ForEach(rows) { t in TargetRow(target: t, tint: info.tint, model: model, snap: snap) }
                }
                if rows.count > 4 && !model.snapshotMode {
                    ScrollView { list }.frame(height: 214)
                } else {
                    list
                }
                if category == .claude {
                    HStack(spacing: 12) {
                        Legend(filled: true, tint: info.tint, text: "has a terminal")
                        Legend(filled: false, tint: info.tint, text: "detached (tmux or no terminal)")
                    }
                }
            }
        }
    }
}

struct Legend: View {
    let filled: Bool
    let tint: Color
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(filled ? tint : .clear).overlay(Circle().strokeBorder(tint, lineWidth: 1.5)).frame(width: 7, height: 7)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct PillButton: View {
    let title: String
    let tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.18)))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

struct BigAction: View {
    let text: String
    let button: String
    let icon: String
    let tint: Color
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                Label(button, systemImage: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(tint.gradient))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }
}

struct TargetRow: View {
    let target: Target
    let tint: Color
    @ObservedObject var model: Model
    let snap: Snapshot
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(target.flag ? Color.clear : tint)
                .overlay(Circle().strokeBorder(tint, lineWidth: 1.5))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.title.isEmpty ? target.label : target.title)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(target.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(mem(target.rssKB))
                .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                model.app?.confirmAndStop([target], title: "Stop \(target.title.isEmpty ? "this process" : target.title)?", intro: target.label)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(hover ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop it and its child processes")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0.035)))
        .onHover { hover = $0 }
        .contextMenu {
            if let p = snap.procs[target.pid] {
                Button("Show where it came from…") { model.app?.showOrigin(p, snap) }
            }
        }
    }
}

// MARK: - Usage bars

struct UsageSection: View {
    @ObservedObject var model: Model
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionTitle(text: "Top usage")
                    Spacer()
                    Segmented(options: ["Memory", "CPU"], selection: $model.usageTab)
                }
                if let snap = model.snap {
                    VStack(spacing: 4) {
                        if model.usageTab == 0 {
                            let maxKB = Double(model.groups.first?.kb ?? 1)
                            ForEach(model.groups) { g in
                                UsageRow(icon: appIcon(g.icon), symbol: g.name == "Claude Code" ? "sparkles" : "terminal",
                                         name: g.name, value: "\(mem(g.kb))  ·  \(g.pids.count)",
                                         fraction: Double(g.kb) / maxKB, tint: .purple)
                                    .contextMenu { groupMenu(g, snap) }
                            }
                        } else {
                            let maxCPU = max(model.topCPU.first?.cpu ?? 1, 1)
                            ForEach(model.topCPU, id: \.pid) { p in
                                UsageRow(icon: appIcon(p.bundlePath), symbol: p.isClaude ? "sparkles" : "terminal",
                                         name: p.display, value: String(format: "%.0f%%", p.cpu) + "  ·  \(mem(p.rssKB))",
                                         fraction: p.cpu / maxCPU, tint: .orange)
                                    .contextMenu { processMenu(p, snap) }
                            }
                        }
                    }
                    Text("Right-click a row to see where it came from or stop it.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    func processMenu(_ p: Proc, _ snap: Snapshot) -> some View {
        Button("Show where it came from…") { model.app?.showOrigin(p, snap) }
        Divider()
        if let app = NSRunningApplication(processIdentifier: p.pid) {
            Button("Quit \(app.localizedName ?? p.name)") { _ = app.terminate() }
            Button("Force quit") { _ = app.forceTerminate() }
        } else {
            Button("Stop") { model.app?.stopOne([p.pid], force: false) }
            Button("Force kill") { model.app?.stopOne([p.pid], force: true) }
            let t = snap.tree(p.pid)
            if t.count > 1 {
                Button("Stop with \(t.count - 1) child processes") { model.app?.stopOne(t, force: false) }
            }
        }
    }

    @ViewBuilder
    func groupMenu(_ g: GroupStat, _ snap: Snapshot) -> some View {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.deletingPathExtension().lastPathComponent == g.name }) {
            Button("Quit \(g.name)") { _ = app.terminate() }
            Button("Force quit \(g.name)") { _ = app.forceTerminate() }
        } else {
            Button("Stop all \(g.pids.count) processes…") {
                let ts = g.pids.compactMap { snap.procs[$0] }.map { Target(pid: $0.pid, label: $0.display, pids: [$0.pid], rssKB: $0.rssKB) }
                model.app?.confirmAndStop(ts, title: "Stop every \(g.name) process?", intro: "")
            }
        }
        if let biggest = g.pids.compactMap({ snap.procs[$0] }).max(by: { $0.rssKB < $1.rssKB }) {
            Button("Where did the largest one come from…") { model.app?.showOrigin(biggest, snap) }
        }
    }
}

struct UsageRow: View {
    let icon: NSImage?
    let symbol: String
    let name: String
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                }
            }
            .frame(width: 18, height: 18)
            Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(alignment: .leading) {
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.12)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, g.size.width * min(fraction, 1)))
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Footer

struct Footer: View {
    @ObservedObject var model: Model
    var body: some View {
        HStack(spacing: 12) {
            Button { model.app?.copyDiagnostics() } label: {
                Label("Copy diagnostics", systemImage: "doc.on.clipboard")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Updated \(model.updated.formatted(date: .omitted, time: .standard))")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            Button { model.app?.showSettingsMenu() } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }
}

struct Segmented: View {
    let options: [String]
    @Binding var selection: Int
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = i }
                } label: {
                    Text(options[i])
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .foregroundStyle(selection == i ? Color.primary : Color.secondary)
                        .background {
                            if selection == i {
                                Capsule().fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}
