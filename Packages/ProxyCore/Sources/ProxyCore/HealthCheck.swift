import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The real check: a delay test (urltest) only times one small HTTP request, so a node can answer it and still fail
/// real traffic (TLS through it breaks, the exit moved to the wrong country, the server answers but forwards
/// nothing). Every few minutes, after every network probe and on demand, each group's candidate in use loads its
/// group's real page through `check·<group>` (`NetworkProbe.verdict`: the page must answer with its content, and
/// from a place valid for the group). Direct comes first: where the probe found it valid, direct is checked and, if
/// it passes, the group goes direct (never raced against the nodes). Direct failing (twice in a row) makes the group
/// fall back to the nodes until a later round finds direct passing again. Among the nodes, if the urltest's pick
/// fails (twice in a row), the selector is pinned to the fastest other node that passes; when the automatic choice
/// passes again the selector goes back to it.
public struct HealthReport: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public let group: String
        public let candidate: String?   // what the group uses after this round
        public let passed: Bool         // `candidate` passed the real check
        public let pinned: Bool         // the automatic choice (direct, else the urltest's pick) failed: `candidate` instead
        public let failed: [String]     // candidates that failed this round (the automatic choice first)
        public let exit: String?        // the passing candidate's exit (country / mainland region, never an IP)
        public let ms: Int?             // its page load time
        public let at: Date
        public init(group: String, candidate: String?, passed: Bool, pinned: Bool, failed: [String], exit: String?,
                    ms: Int?, at: Date = Date()) {
            self.group = group; self.candidate = candidate; self.passed = passed; self.pinned = pinned
            self.failed = failed; self.exit = exit; self.ms = ms; self.at = at
        }
    }
    public var entries: [String: Entry]
    public init(entries: [String: Entry] = [:]) { self.entries = entries }
}

public struct HealthCheck {
    public struct Result: Equatable {
        public let passed: Bool
        public let exit: String?
        public let ms: Int?
        public init(passed: Bool, exit: String?, ms: Int?) { self.passed = passed; self.exit = exit; self.ms = ms }
    }
    /// Seconds between rounds while the tunnel runs. Also how long a group can stay on a direct route that broke
    /// without a network change (a network change re-probes within seconds); a round on a working route costs one
    /// small page per group.
    public static let interval: UInt64 = 60
    /// At most this many other candidates are tried when the pick fails.
    public static let maxTries = 6

    /// Clash API calls (the extension's loopback controller, or the replica's desktop sing-box).
    public let call: @Sendable (ClashCall.Request) async -> ClashCall.Response
    /// Loads one group's real page through the given loopback check port (a mixed inbound) and returns the verdict.
    public let load: @Sendable (_ group: String, _ port: Int) async -> Result
    /// group tag -> its check inbound's port
    public let ports: [String: Int]

    public init(call: @escaping @Sendable (ClashCall.Request) async -> ClashCall.Response,
                load: @escaping @Sendable (_ group: String, _ port: Int) async -> Result, ports: [String: Int]) {
        self.call = call; self.load = load; self.ports = ports
    }

    /// The check inbounds' ports in a built config.
    public static func ports(config: String) -> [String: Int] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any],
              let ins = obj["inbounds"] as? [[String: Any]] else { return [:] }
        var r: [String: Int] = [:]
        for i in ins {
            guard let tag = i["tag"] as? String, tag.hasPrefix(Plan.checkInPrefix),
                  let p = (i["listen_port"] as? NSNumber)?.intValue else { continue }
            r[String(tag.dropFirst(Plan.checkInPrefix.count))] = p
        }
        return r
    }

    /// One round over every group (in parallel: each group has its own check selector and port).
    public func run(directAllowed: [String: Bool]) async -> HealthReport {
        let r = await call(ClashCall.proxies)
        guard r.status == 200, let state = try? ProxyState.parse(Data(r.body.utf8), directAllowed: directAllowed) else {
            return HealthReport()
        }
        var report = HealthReport()
        await withTaskGroup(of: HealthReport.Entry?.self) { tg in
            for g in state.groups {
                tg.addTask { await self.round(g) }
            }
            for await e in tg { if let e { report.entries[e.group] = e } }
        }
        return report
    }

    func check(_ group: ProxyState.Group, _ candidate: String) async -> Result {
        guard let plan = Plan.group(group.tag), let port = ports[group.tag] else { return Result(passed: false, exit: nil, ms: nil) }
        guard (200..<300).contains(await call(ClashCall.select(plan.checkSelector, candidate)).status) else {
            return Result(passed: false, exit: nil, ms: nil)
        }
        return await load(group.tag, port)
    }

    /// Passes when either of two tries passes (one lost request is not a broken node).
    func checkTwice(_ group: ProxyState.Group, _ candidate: String) async -> Result {
        let first = await check(group, candidate)
        return first.passed ? first : await check(group, candidate)
    }

    func round(_ group: ProxyState.Group) async -> HealthReport.Entry? {
        guard let plan = Plan.group(group.tag) else { return nil }
        var failed: [String] = []
        func entry(_ c: String?, _ r: Result?, pinned: Bool) -> HealthReport.Entry {
            HealthReport.Entry(group: group.tag, candidate: c, passed: r?.passed ?? false, pinned: pinned, failed: failed,
                               exit: r?.exit, ms: r?.ms)
        }
        func use(_ member: String) async { if group.selected != member { _ = await call(ClashCall.select(plan.tag, member)) } }
        // 1. direct, where this network allows it: passing means the group goes direct, whatever the nodes measure
        if group.directAllowed {
            let d = await checkTwice(group, plan.direct)
            if d.passed {
                await use(plan.direct)
                return entry(plan.direct, d, pinned: false)
            }
            failed.append(plan.direct)
        }
        // 2. the nodes' urltest pick (the fallback when direct is unavailable or failed)
        if let pick = group.nodesPick, !failed.contains(pick) {
            let a = await checkTwice(group, pick)
            if a.passed {
                await use(plan.nodesTest)
                return entry(pick, a, pinned: group.directAllowed)
            }
            failed.append(pick)
        }
        // 3. a node pinned earlier that still passes stays
        let cur = group.selected
        if cur != plan.nodesTest, cur != plan.direct, !failed.contains(cur), group.candidates.contains(where: { $0.tag == cur }) {
            let p = await checkTwice(group, cur)
            if p.passed { return entry(cur, p, pinned: true) }
            failed.append(cur)
        }
        // 4. the fastest others by their last delay (tested ones first, timeouts last)
        let order = group.candidates.filter { !failed.contains($0.tag) }.sorted { x, y in
            func key(_ d: Int?) -> Int { d.map { $0 > 0 ? $0 : Int.max - 1 } ?? Int.max }
            return key(x.delay) < key(y.delay)
        }
        for c in order.prefix(Self.maxTries) {
            let r = await check(group, c.tag)
            if r.passed {
                await use(c.tag)
                return entry(c.tag, r, pinned: true)
            }
            failed.append(c.tag)
        }
        // 5. nothing passed: back to the automatic choice (direct where allowed)
        let automatic = plan.automatic(directAllowed: group.directAllowed)
        await use(automatic)
        return entry(group.directAllowed ? plan.direct : group.nodesPick, nil, pinned: false)
    }

    /// Loads `group`'s real page through the loopback check inbound on `port` (an HTTP proxy; HTTPS goes through it
    /// with CONNECT), 10 s per request, with a fresh session so no connection is reused across candidates.
    /// Apple platforms only: Foundation on Linux ignores a session's proxy settings (proxy-config uses curl there).
    public static func load(group: String, port: Int) async -> Result {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
                                         "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port]
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        let t = Date()
        let v = await NetworkProbe.verdict(group) { await NetworkProbe.get($0, session: session, timeout: 10) }
        return Result(passed: v.valid, exit: v.exit, ms: v.exit == nil ? nil : Int(Date().timeIntervalSince(t) * 1000))
    }
}
