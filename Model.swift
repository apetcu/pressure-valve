// Model layer: system stats, process snapshot, and the suspects worth stopping.
import AppKit
import Darwin

// MARK: - Helpers

@discardableResult
func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func gb(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
func mem(_ kb: Int) -> String {
    kb >= 1_048_576 ? String(format: "%.1f GB", Double(kb) / 1_048_576) : "\(kb / 1024) MB"
}
func age(_ s: Int) -> String {
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}
func trunc(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
func redact(_ s: String) -> String {
    s.replacingOccurrences(of: #"((?:key|token|secret|password)[=:\s]+)\S+"#, with: "$1•••",
                           options: [.regularExpression, .caseInsensitive])
}
func tilde(_ p: String) -> String {
    let home = NSHomeDirectory()
    return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
}
func parseEtime(_ s: String) -> Int {
    var days = 0
    var rest = Substring(s)
    if let d = s.firstIndex(of: "-") { days = Int(s[..<d]) ?? 0; rest = s[s.index(after: d)...] }
    return days * 86400 + rest.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
}
func firstMatch(_ pattern: String, in s: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[r])
}

// MARK: - System stats (cheap, no subprocesses)

enum Severity: Int, Comparable {
    case ok, warn, crit
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    var label: String { ["Normal", "Elevated", "Critical"][rawValue] }
}

struct Stats {
    var load: [Double] = [0, 0, 0]
    var cores = ProcessInfo.processInfo.activeProcessorCount
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: Int32 = 1
    var memUsed: UInt64 = 0
    var memTotal = ProcessInfo.processInfo.physicalMemory

    static func read() -> Stats {
        var s = Stats()
        getloadavg(&s.load, 3)
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 {
            s.swapUsed = xsw.xsu_used; s.swapTotal = xsw.xsu_total
        }
        var lvl: Int32 = 1
        var lsize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &lvl, &lsize, nil, 0) == 0 { s.pressure = lvl }
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(sysconf(_SC_PAGESIZE))
            let anon = UInt64(vm.internal_page_count)
            let appPages = anon - min(UInt64(vm.purgeable_count), anon)
            s.memUsed = (appPages + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        }
        return s
    }

    var pressureLabel: String { pressure >= 4 ? "Critical" : pressure == 2 ? "Warning" : "Normal" }

    var severity: Severity {
        var s = Severity.ok
        let ratio = load[0] / Double(max(cores, 1))
        if ratio > 2 { s = max(s, .warn) }
        if ratio > 5 { s = .crit }
        if pressure == 2 { s = max(s, .warn) }
        if pressure >= 4 { s = .crit }
        let swapFrac = Double(swapUsed) / Double(max(memTotal, 1))
        if swapFrac > 0.25 { s = max(s, .warn) }
        if swapFrac > 0.6 { s = .crit }
        return s
    }
}

// MARK: - Process snapshot (taken only when the menu opens)

struct Proc {
    let pid: Int32
    let ppid: Int32
    let cpu: Double
    let rssKB: Int
    let ageSec: Int
    let tty: String
    let path: String
    var args = ""

    var name: String { (path as NSString).lastPathComponent }
    var isClaude: Bool { path.contains("/.local/share/claude/versions/") || name == "claude" }
    /// Bundle-level grouping: every Chrome helper counts as "Google Chrome", etc.
    var group: String {
        if isClaude { return "Claude Code" }
        if path.hasPrefix("npm ") { return "npm exec (MCP servers, tools)" }
        if let r = path.range(of: ".app/") {
            return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
        }
        return name
    }
    /// The outermost .app bundle this process lives in, used for its icon.
    var bundlePath: String? {
        path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" }
    }
    var display: String {
        if path.hasPrefix("npm ") { return trunc(redact(path), 60) }
        return trunc(name, 60)
    }
}

final class Snapshot {
    var procs: [Int32: Proc] = [:]
    var kids: [Int32: [Int32]] = [:]
    var cwd: [Int32: String] = [:]
    /// Shown process count when it differs from `procs` (demo data).
    var total: Int?

    /// A fixed set of processes instead of a live `ps` scan.
    init(fake: [Proc], total: Int) {
        for p in fake { procs[p.pid] = p }
        self.total = total
    }

    init() {
        let out = run("/bin/ps", ["-Ao", "pid=,ppid=,%cpu=,rss=,etime=,tty=,comm="])
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
            guard f.count == 7, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            procs[pid] = Proc(pid: pid, ppid: ppid, cpu: Double(f[2]) ?? 0, rssKB: Int(f[3]) ?? 0,
                              ageSec: parseEtime(String(f[4])), tty: String(f[5]),
                              path: f[6].trimmingCharacters(in: .whitespaces))
            if pid != ppid { kids[ppid, default: []].append(pid) }
        }
        let a = run("/bin/ps", ["-Awwo", "pid=,args="])
        for line in a.split(separator: "\n") {
            let t = line.drop(while: { $0 == " " })
            guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]) else { continue }
            procs[pid]?.args = String(t[t.index(after: sp)...])
        }
    }

    /// Working directories for a handful of pids, in a single lsof call.
    func loadCwds(_ pids: [Int32]) {
        guard !pids.isEmpty else { return }
        let out = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", pids.map { String($0) }.joined(separator: ",")])
        var cur: Int32 = 0
        for l in out.split(separator: "\n") {
            if l.hasPrefix("p") { cur = Int32(l.dropFirst()) ?? 0 }
            else if l.hasPrefix("n") { cwd[cur] = String(l.dropFirst()) }
        }
    }

    /// The process and all of its descendants, children first.
    func tree(_ pid: Int32) -> [Int32] {
        var out: [Int32] = []
        var seen = Set<Int32>()
        func walk(_ p: Int32) {
            guard seen.insert(p).inserted else { return }
            for c in kids[p] ?? [] { walk(c) }
            out.append(p)
        }
        walk(pid)
        return out
    }
    func treeRSS(_ pid: Int32) -> Int { tree(pid).reduce(0) { $0 + (procs[$1]?.rssKB ?? 0) } }

    func ancestors(_ pid: Int32) -> [Proc] {
        var out: [Proc] = []
        var cur = procs[pid]?.ppid ?? 0
        while cur > 0, let p = procs[cur], out.count < 40 {
            out.append(p)
            if p.ppid == cur { break }
            cur = p.ppid
        }
        return out
    }

    /// The app, terminal or tmux server a process ultimately came from.
    func origin(_ pid: Int32) -> String {
        for a in ancestors(pid) {
            if a.name == "tmux" { return "tmux" }
            if a.path.contains(".app/") && !a.isClaude { return a.group }
        }
        return "launchd"
    }
}

// MARK: - Things worth stopping

struct Target: Identifiable {
    let pid: Int32
    /// One line, used in confirmation dialogs and diagnostics.
    let label: String
    let pids: [Int32]
    let rssKB: Int
    var title = ""
    var detail = ""
    /// For Claude sessions: detached (tmux or no terminal).
    var flag = false
    var id: Int32 { pid }
}

func sum(_ ts: [Target]) -> Int { ts.reduce(0) { $0 + $1.rssKB } }

struct Suspects {
    var monitors: [Target] = []
    var claude: [Target] = []
    var orphanMCP: [Target] = []
    var devServers: [(t: Target, ageSec: Int)] = []
    var simRSS = 0
    var simBooted = false
    var chromeRSS = 0

    init(_ snap: Snapshot) {
        let me = getpid()
        let mine = Set(snap.ancestors(me).map(\.pid))
        let all = Array(snap.procs.values)

        for p in all {
            let isAM = p.path.hasSuffix("Activity Monitor.app/Contents/MacOS/Activity Monitor")
            let isCMM = p.path.contains("CleanMyMac") && (p.path.contains("HealthMonitor") || p.path.hasSuffix(".Menu"))
            if isAM || isCMM {
                let name = isAM ? "Activity Monitor" : p.name.replacingOccurrences(of: "com.macpaw.", with: "")
                monitors.append(Target(pid: p.pid, label: name, pids: [p.pid], rssKB: p.rssKB,
                                       title: name, detail: "PID \(p.pid) · up \(age(p.ageSec))"))
            }
        }

        // Claude Code sessions, skipping our own ancestors and nested claude processes.
        let claudes = all.filter { $0.isClaude && !mine.contains($0.pid) && $0.pid != me }
        let claudeSet = Set(claudes.map(\.pid))
        let topClaudes = claudes.filter { c in !snap.ancestors(c.pid).contains { claudeSet.contains($0.pid) } }

        for p in all where p.ppid == 1 && p.args.lowercased().contains("mcp") && !p.path.contains(".app/") {
            orphanMCP.append(Target(pid: p.pid, label: p.display, pids: snap.tree(p.pid), rssKB: snap.treeRSS(p.pid),
                                    title: p.display, detail: "PID \(p.pid) · orphaned · up \(age(p.ageSec))"))
        }

        let devPattern = try! NSRegularExpression(
            pattern: #"expo start|next dev|next-server|\bvite\b|react-native start|metro|webpack serve|webpack-dev-server|nodemon|storybook|turbo (run )?dev"#,
            options: [.caseInsensitive])
        let devs = all.filter { p in
            let a = p.args.isEmpty ? p.path : p.args
            return !p.path.contains(".app/") && !a.lowercased().contains("mcp")
                && devPattern.firstMatch(in: a, range: NSRange(a.startIndex..., in: a)) != nil
        }
        let devSet = Set(devs.map(\.pid))
        let roots = devs.filter { d in !snap.ancestors(d.pid).contains { devSet.contains($0.pid) } }

        snap.loadCwds(topClaudes.map(\.pid) + roots.map(\.pid))

        for p in topClaudes {
            let viaTmux = snap.ancestors(p.pid).contains { $0.name == "tmux" }
            let detached = p.tty == "??" || viaTmux
            let rss = snap.treeRSS(p.pid)
            let dir = snap.cwd[p.pid].map { tilde($0) } ?? "?"
            let term = p.tty == "??" ? "no terminal" : p.tty
            let label = "\(trunc(dir, 40))  ·  \(snap.origin(p.pid)), \(term)  ·  \(age(p.ageSec))  ·  \(mem(rss))"
            claude.append(Target(pid: p.pid, label: label, pids: snap.tree(p.pid), rssKB: rss,
                                 title: trunc(dir, 48),
                                 detail: "\(snap.origin(p.pid)) · \(term) · up \(age(p.ageSec)) · \(snap.tree(p.pid).count) procs",
                                 flag: detached))
        }
        claude.sort { $0.rssKB > $1.rssKB }

        for r in roots {
            let a = (r.args.isEmpty ? r.path : r.args).lowercased()
            let kind = ["expo", "next", "vite", "metro", "webpack", "nodemon", "storybook", "turbo", "react-native"]
                .first { a.contains($0) } ?? "dev"
            let dir = snap.cwd[r.pid].map { ($0 as NSString).lastPathComponent } ?? "?"
            let port = firstMatch(#"(?:--port|-p)[ =](\d{2,5})"#, in: a).map { " :\($0)" } ?? ""
            let rss = snap.treeRSS(r.pid)
            devServers.append((Target(pid: r.pid, label: "\(kind) · \(dir)\(port)  ·  \(age(r.ageSec))  ·  \(mem(rss))",
                                      pids: snap.tree(r.pid), rssKB: rss,
                                      title: "\(kind) · \(dir)",
                                      detail: (port.isEmpty ? "" : "port\(port) · ") + "up \(age(r.ageSec)) · \(snap.tree(r.pid).count) procs",
                                      flag: r.ageSec > 12 * 3600), r.ageSec))
        }
        devServers.sort { $0.ageSec > $1.ageSec }

        simBooted = all.contains { $0.name == "launchd_sim" }
        simRSS = all.filter { $0.path.contains("CoreSimulator") || $0.path.contains("Simulator.app/") }.reduce(0) { $0 + $1.rssKB }
        chromeRSS = all.filter { $0.group == "Google Chrome" }.reduce(0) { $0 + $1.rssKB }
    }

    var detachedClaude: [Target] { claude.filter(\.flag) }
    var staleDev: [Target] { devServers.filter { $0.ageSec > 12 * 3600 }.map(\.t) }
}

