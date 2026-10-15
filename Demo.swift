// Made-up data for README screenshots (--snapshot … --demo), so no real paths leak.
import Foundation

extension Suspects {
    init() {}
}

extension Model {
    func loadDemo() {
        let gb = 1024 * 1024
        var s = Stats()
        s.cores = 10
        s.load = [31.4, 24.8, 16.2]
        s.memTotal = 64 * 1024 * 1024 * 1024
        s.memUsed = 51 * 1024 * 1024 * 1024
        s.swapUsed = 9 * 1024 * 1024 * 1024
        s.swapTotal = 12 * 1024 * 1024 * 1024
        s.pressure = 2
        stats = s
        history = (0..<60).map { i in
            let t = Double(i) / 59
            let wave = sin(Double(i) / 4) * 2.5 + sin(Double(i) / 1.7) * 1.2
            return Sample(id: i, load: 12 + 19 * t * t + wave)
        }

        func t(_ pid: Int32, _ title: String, _ detail: String, _ kb: Int, flag: Bool = false) -> Target {
            Target(pid: pid, label: "\(title) · \(detail)", pids: [pid], rssKB: kb, title: title, detail: detail, flag: flag)
        }
        var x = Suspects()
        x.claude = [
            t(4101, "~/Projects/acme-web", "tmux · no terminal · up 2d 4h · 19 procs", 3_400_000, flag: true),
            t(4102, "~/Projects/acme-api", "Terminal · ttys004 · up 1d 7h · 14 procs", 2_700_000),
            t(4103, "~/Projects/side-quest", "tmux · no terminal · up 22h 10m · 11 procs", 2_100_000, flag: true),
            t(4104, "~/Projects/dotfiles", "VS Code · ttys011 · up 3h 12m · 8 procs", 1_200_000),
        ]
        x.devServers = [
            (t(5201, "next · acme-web", "port :3000 · up 1d 2h · 42 procs", 1_900_000, flag: true), 93_600),
            (t(5202, "vite · design-kit", "port :5173 · up 4h 40m · 9 procs", 620_000), 16_800),
        ]
        x.monitors = [
            t(6301, "Activity Monitor", "PID 6301 · up 5h 2m", 210_000),
            t(6302, "HealthMonitor", "PID 6302 · up 9d 1h", 180_000),
        ]
        x.orphanMCP = [
            t(7401, "npm exec @example/mcp-server", "PID 7401 · orphaned · up 1d 5h", 340_000),
        ]
        x.simBooted = true
        x.simRSS = 3 * gb
        x.chromeRSS = 7 * gb
        sus = x

        func g(_ name: String, _ kb: Int, _ app: String?, _ n: Int) -> GroupStat {
            GroupStat(name: name, kb: kb, pids: Array(repeating: 0, count: n), icon: app.map { "/Applications/\($0).app" })
        }
        groups = [
            g("Google Chrome", 7 * gb, "Google Chrome", 46),
            g("Claude Code", 9 * gb + 400_000, nil, 52),
            g("Xcode", 4 * gb, "Xcode", 7),
            g("Docker", 3 * gb + 500_000, "Docker", 12),
            g("node", 2 * gb + 600_000, nil, 23),
            g("Slack", 1 * gb + 300_000, "Slack", 6),
            g("Figma", 900_000, "Figma", 5),
            g("Spotify", 450_000, "Spotify", 4),
        ].sorted { $0.kb > $1.kb }

        func p(_ pid: Int32, _ cpu: Double, _ kb: Int, _ path: String) -> Proc {
            Proc(pid: pid, ppid: 1, cpu: cpu, rssKB: kb, ageSec: 3600, tty: "??", path: path)
        }
        topCPU = [
            p(8001, 186.0, 1_400_000, "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (Renderer)"),
            p(8002, 94.2, 1_100_000, "/usr/local/bin/node"),
            p(8003, 71.5, 900_000, "/Applications/Xcode.app/Contents/MacOS/Xcode"),
            p(8004, 48.0, 600_000, "claude"),
            p(8005, 33.1, 300_000, "/System/Library/Frameworks/CoreServices.framework/mds_stores"),
            p(8006, 21.7, 250_000, "/Applications/Docker.app/Contents/MacOS/com.docker.backend"),
            p(8007, 12.4, 400_000, "/Applications/Slack.app/Contents/MacOS/Slack"),
            p(8008, 6.3, 120_000, "/System/Library/CoreServices/WindowServer"),
        ]
        snap = Snapshot(fake: topCPU, total: 1042)
        updated = Date()
        loading = false
    }
}
