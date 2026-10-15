// Pressure Valve: a menu bar app that shows system pressure and stops
// the usual suspects (idle Claude sessions, orphaned MCP servers, stale dev
// servers, simulators, a bloated Chrome) with one click.
import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let model = Model()
    var timer: Timer?
    var lastSeverity = Severity.ok
    var lastNotified = Date.distantPast

    func applicationDidFinishLaunching(_ n: Notification) {
        model.app = self
        let host = NSHostingController(rootView: ContentView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        if let b = status.button {
            b.imagePosition = .imageLeft
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        tick()
        model.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Status item

    @objc func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: "Copy diagnostics", action: #selector(copyDiagnosticsAction), keyEquivalent: "").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Quit Pressure Valve", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            status.menu = m
            sender.performClick(nil)
            status.menu = nil
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Small ring drawn for the menu bar: arc length tracks load, color tracks severity.
    func statusImage(_ s: Stats) -> NSImage {
        let sev = s.severity
        let ratio = s.load[0] / Double(max(s.cores, 1))
        let frac = max(0.08, min(ratio / 6, 1))
        let color: NSColor = sev == .crit ? .systemRed : sev == .warn ? .systemOrange : .labelColor
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let rect = r.insetBy(dx: 2.5, dy: 2.5)
            let track = NSBezierPath(ovalIn: rect)
            track.lineWidth = 2.2
            NSColor.tertiaryLabelColor.setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: rect.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * frac, clockwise: true)
            arc.lineWidth = 2.2
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
            let d: CGFloat = 4.5
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    func tick() {
        model.tick()
        let s = model.stats
        let sev = s.severity
        guard let b = status.button else { return }
        b.image = statusImage(s)
        if model.showLoad {
            let color: NSColor = sev == .crit ? .systemRed : sev == .warn ? .systemOrange : .labelColor
            b.attributedTitle = NSAttributedString(string: " \(Int(s.load[0].rounded()))", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: color,
                .baselineOffset: 0.5,
            ])
        } else {
            b.title = ""
        }
        b.toolTip = String(format: "Load %.0f on %d cores · swap %@ · memory pressure %@",
                           s.load[0], s.cores, gb(s.swapUsed), s.pressureLabel)
        if model.notify, sev == .crit, lastSeverity != .crit, Date().timeIntervalSince(lastNotified) > 600 {
            lastNotified = Date()
            notify("System pressure is critical",
                   String(format: "Load %.0f on %d cores, %@ swap. Click the gauge in the menu bar to relieve it.",
                          s.load[0], s.cores, gb(s.swapUsed)))
        }
        lastSeverity = sev
    }

    func notify(_ title: String, _ body: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(esc(body))\" with title \"Pressure Valve\" subtitle \"\(esc(title))\""
        DispatchQueue.global().async { run("/usr/bin/osascript", ["-e", script]) }
    }

    // MARK: Actions

    func confirm(_ title: String, _ text: String, _ button: String) -> Bool {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    func confirmAndStop(_ targets: [Target], title: String, intro: String) {
        guard !targets.isEmpty else { return }
        let lines = targets.prefix(15).map { "• " + ($0.label.isEmpty ? "PID \($0.pid)" : $0.label) }
        let more = targets.count > 15 ? "\n…and \(targets.count - 15) more" : ""
        let pids = Array(Set(targets.flatMap(\.pids)))
        let text = (intro.isEmpty ? "" : intro + "\n\n") + lines.joined(separator: "\n") + more
            + "\n\n\(pids.count) processes, about \(mem(sum(targets))) of memory."
        guard confirm(title, text, "Stop") else { return }
        let failed = stop(pids)
        if failed.isEmpty {
            notify("Stopped \(pids.count) processes", "Freed about \(mem(sum(targets))).")
        } else {
            showFailures(failed)
        }
    }

    func stopOne(_ pids: [Int32], force: Bool) {
        let failed = stop(pids, force: force, escalate: false)
        if !failed.isEmpty { showFailures(failed) }
    }

    /// Sends SIGTERM (or SIGKILL) and escalates stragglers to SIGKILL after 5 s.
    /// Returns the pids macOS refused, which usually belong to root.
    func stop(_ pids: [Int32], force: Bool = false, escalate: Bool = true) -> [Int32] {
        let me = getpid()
        let list = pids.filter { $0 > 1 && $0 != me }
        var failed: [Int32] = []
        for p in list where kill(p, force ? SIGKILL : SIGTERM) != 0 && errno == EPERM { failed.append(p) }
        if !force && escalate {
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                for p in list where kill(p, 0) == 0 { kill(p, SIGKILL) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.tick()
            self?.model.refresh()
        }
        return failed
    }

    func showFailures(_ failed: [Int32]) {
        let list = failed.map { String($0) }.joined(separator: " ")
        _ = confirm("Some processes belong to another user",
                    "macOS refused to stop PIDs \(list). They are probably owned by root. Stop them from Terminal with:\n\nsudo kill \(list)",
                    "OK")
    }

    func showOrigin(_ p: Proc, _ snap: Snapshot) {
        snap.loadCwds([p.pid])
        var text = "Up \(age(p.ageSec)) · \(mem(p.rssKB)) · \(String(format: "%.0f", p.cpu))% CPU · terminal \(p.tty)\n"
        if let d = snap.cwd[p.pid] { text += "Working directory: \(tilde(d))\n" }
        text += "\nCommand:\n\(trunc(redact(p.args.isEmpty ? p.path : p.args), 400))\n\nLaunched by:\n"
        for a in snap.ancestors(p.pid) {
            let cmd = redact(a.args.isEmpty ? a.path : a.args).replacingOccurrences(of: NSHomeDirectory(), with: "~")
            text += "  \(a.pid)  \(trunc(cmd, 70))\n"
        }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "\(p.display) (PID \(p.pid))"
        a.informativeText = text
        if let icon = appIcon(p.bundlePath) { a.icon = icon }
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Copy")
        if a.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(a.messageText + "\n" + text, forType: .string)
        }
    }

    func shutdownSimulators(_ rss: Int) {
        guard confirm("Shut down all booted simulators?", "Runs simctl shutdown all and quits Simulator.", "Shut Down") else { return }
        DispatchQueue.global().async {
            run("/usr/bin/xcrun", ["simctl", "shutdown", "all"])
            DispatchQueue.main.async { [weak self] in
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator").forEach { $0.terminate() }
                self?.notify("Simulators shut down", "Freed about \(mem(rss)).")
                self?.tick()
                self?.model.refresh()
            }
        }
    }

    func restartChrome() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first,
              let url = app.bundleURL else { return }
        guard confirm("Restart Chrome?",
                      "Chrome quits and reopens. Tabs come back if \"Continue where you left off\" is on in Chrome's On startup settings, and they reload lazily so memory stays low.",
                      "Restart") else { return }
        app.terminate()
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(30)
            while !app.isTerminated && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
            let done = app.isTerminated
            DispatchQueue.main.async { [weak self] in
                guard done else {
                    _ = self?.confirm("Chrome didn't quit", "It may be showing a \"Leave site?\" dialog. Check Chrome and try again.", "OK")
                    return
                }
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                self?.tick()
            }
        }
    }

    @objc func copyDiagnosticsAction() { copyDiagnostics() }

    func showSettingsMenu() {
        let menu = NSMenu()
        func toggle(_ title: String, _ on: Bool, _ action: @escaping () -> Void) {
            let item = ClosureItem(title, action)
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        toggle("Show load number in menu bar", model.showLoad) { self.model.showLoad.toggle() }
        toggle("Notify when pressure turns critical", model.notify) { self.model.notify.toggle() }
        toggle("Launch at login", model.launchAtLogin) { self.model.launchAtLogin.toggle() }
        menu.addItem(.separator())
        menu.addItem(ClosureItem("Quit Pressure Valve") { NSApp.terminate(nil) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func copyDiagnostics() {
        guard let snap = model.snap, let f = model.sus else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics(model.stats, snap, f, model.groups), forType: .string)
        notify("Diagnostics copied", "Paste them into Claude or a note.")
    }
}

final class ClosureItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

func diagnostics(_ s: Stats, _ snap: Snapshot, _ f: Suspects, _ groups: [GroupStat]) -> String {
    var out = String(format: "Load %.1f / %.1f / %.1f on %d cores\n", s.load[0], s.load[1], s.load[2], s.cores)
    out += "Memory \(gb(s.memUsed)) of \(gb(s.memTotal)), pressure \(s.pressureLabel). Swap \(gb(s.swapUsed)) of \(gb(s.swapTotal)). \(snap.procs.count) processes.\n\nTop CPU:\n"
    for p in snap.procs.values.sorted(by: { $0.cpu > $1.cpu }).prefix(12) {
        out += String(format: "%6.1f%%  %6d  ", p.cpu, p.pid) + "\(mem(p.rssKB))  from \(snap.origin(p.pid))  \(p.display)\n"
    }
    out += "\nTop memory by app:\n"
    for g in groups { out += "  \(mem(g.kb))  \(g.name) (\(g.pids.count))\n" }
    out += "\nClaude Code sessions:\n" + f.claude.map { "  \($0.flag ? "detached" : "attached")  \($0.label)\n" }.joined()
    out += "\nDev servers:\n" + f.devServers.map { "  \($0.t.label)\n" }.joined()
    out += "\nMonitors: " + f.monitors.map { "\($0.title) [\($0.pid)]" }.joined(separator: ", ") + "\n"
    out += "Orphaned MCP servers: \(f.orphanMCP.count) (\(mem(sum(f.orphanMCP))))\n"
    out += "Simulator booted: \(f.simBooted) (\(mem(f.simRSS))) · Chrome \(mem(f.chromeRSS))\n"
    return out
}

// MARK: - Entry point

let args = CommandLine.arguments

if args.contains("--report") {
    let m = Model()
    m.refreshSync()
    print(diagnostics(m.stats, m.snap!, m.sus!, m.groups))
    exit(0)
}

let app = NSApplication.shared

// Render the popover to a PNG without showing UI: --snapshot out.png [--dark] [--select claude|dev|...] [--cpu] [--demo]
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    let dark = args.contains("--dark")
    app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    MainActor.assumeIsolated {
        let m = Model()
        m.snapshotMode = true
        if args.contains("--demo") { m.loadDemo() } else { m.refreshSync() }
        if let j = args.firstIndex(of: "--select"), j + 1 < args.count { m.selected = Category(rawValue: args[j + 1]) }
        if args.contains("--cpu") { m.usageTab = 1 }
        let view = ContentView(model: m)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let cg = r.cgImage,
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: args[i + 1]))
            print("Wrote \(args[i + 1]) (\(cg.width)×\(cg.height))")
        }
    }
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
