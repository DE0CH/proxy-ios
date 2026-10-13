import Foundation
import NetworkExtension
import ProxyCore
import SwiftUI

/// How the app reaches sing-box's Clash API.
protocol ClashChannel {
    func call(_ r: ClashCall.Request) async throws -> ClashCall.Response
}

/// The real path: an app message to the packet tunnel, which forwards it to its loopback controller.
struct ProviderChannel: ClashChannel {
    let session: NETunnelProviderSession
    func call(_ r: ClashCall.Request) async throws -> ClashCall.Response {
        try await send(["clash": ["method": r.method, "path": r.path, "body": r.body as Any]])
    }
    /// The extension's last network probe (`now`: probe again first).
    func probe(now: Bool) async throws -> ProbeResult? {
        let r = try await send(["probe": now])
        guard r.status == 200 else { return nil }
        return try JSONDecoder().decode(ProbeResult.self, from: Data(r.body.utf8))
    }
    private func send(_ obj: [String: Any]) async throws -> ClashCall.Response {
        let msg = try JSONSerialization.data(withJSONObject: obj)
        return try await withCheckedThrowingContinuation { c in
            do {
                try session.sendProviderMessage(msg) { data in
                    guard let data, let resp = try? JSONDecoder().decode(ClashCall.Response.self, from: data) else {
                        c.resume(throwing: PacketError.noReply); return
                    }
                    c.resume(returning: resp)
                }
            } catch { c.resume(throwing: error) }
        }
    }
}

/// Simulator/UI tests: a desktop sing-box's Clash API over plain HTTP (PROXY_MOCK_CLASH / PROXY_MOCK_SECRET).
struct HTTPChannel: ClashChannel {
    let base: URL
    let secret: String
    func call(_ r: ClashCall.Request) async throws -> ClashCall.Response {
        var req = URLRequest(url: URL(string: r.path, relativeTo: base)!, timeoutInterval: 30)
        req.httpMethod = r.method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let b = r.body { req.httpBody = Data(b.utf8) }
        let (d, resp) = try await URLSession.shared.data(for: req)
        return ClashCall.Response(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: String(decoding: d, as: UTF8.self))
    }
}

enum PacketError: LocalizedError {
    case noReply
    var errorDescription: String? { "no reply from the tunnel" }
}

@MainActor
final class TunnelController: ObservableObject {
    @Published var status: NEVPNStatus = .invalid
    @Published var state: ProxyState?
    @Published var probe: ProbeResult?
    @Published var probing = false
    @Published var message: String?
    @Published var testLines: [String] = []
    @Published var testing = false
    @Published var working = false
    @Published var apiError: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var poller: Task<Void, Never>?
    let mock: HTTPChannel?
    private let mockHTTPProxy: (String, Int)?
    private let mockProbe: String?

    static let tunnelBundleID = "dev.de0ch.proxy.tunnel"

    init() {
        let env = ProcessInfo.processInfo.environment
        if let b = env["PROXY_MOCK_CLASH"], let u = URL(string: b) {
            mock = HTTPChannel(base: u, secret: env["PROXY_MOCK_SECRET"] ?? "")
            status = .connected
        } else {
            mock = nil
        }
        if let p = env["PROXY_MOCK_HTTP_PROXY"], let i = p.lastIndex(of: ":"), let port = Int(p[p.index(after: i)...]) {
            mockHTTPProxy = (String(p[..<i]), port)
        } else {
            mockHTTPProxy = nil
        }
        mockProbe = env["PROXY_MOCK_PROBE"]
    }

    var connected: Bool { status == .connected }

    private var provider: ProviderChannel? {
        guard connected, let s = manager?.connection as? NETunnelProviderSession else { return nil }
        return ProviderChannel(session: s)
    }

    private var channel: ClashChannel? { mock ?? provider }

    func load() async {
        guard mock == nil else { await recheckNetwork(); startPolling(); return }
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = all.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.tunnelBundleID }
        } catch { message = "Couldn't read the VPN profile: \(error.localizedDescription)" }
        if let manager {
            status = manager.connection.status
            observe(manager)
        }
        startPolling()
    }

    private func observe(_ m: NETunnelProviderManager) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: m.connection, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.status = m.connection.status
                if self.status == .connected { await self.refresh() } else if self.status == .disconnected { self.state = nil; self.probe = nil }
            }
        }
    }

    private func ensureManager() async throws -> NETunnelProviderManager {
        let m = manager ?? NETunnelProviderManager()
        let proto = (m.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.tunnelBundleID
        proto.serverAddress = "sing-box"
        m.protocolConfiguration = proto
        m.localizedDescription = "Proxy"
        m.isEnabled = true
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        if manager == nil { observe(m) }
        manager = m
        return m
    }

    private func buildConfig() async throws -> String {
        let subs = await Subscriptions.fetchAll()
        let notes = subs.notes
        let r = try ConfigBuilder.build(subscriptions: subs.data, options: BuildOptions(clashSecret: UUID().uuidString))
        let all = notes + r.warnings
        message = all.isEmpty ? nil : all.joined(separator: "\n")
        return r.json
    }

    func setConnected(_ on: Bool) async {
        guard mock == nil else { return }
        working = true
        defer { working = false }
        do {
            if on {
                let cfg = try await buildConfig()
                let m = try await ensureManager()
                try m.connection.startVPNTunnel(options: ["config": cfg as NSString])
            } else {
                manager?.connection.stopVPNTunnel()
            }
        } catch {
            message = "\(on ? "Connect" : "Disconnect") failed: \(error.localizedDescription)"
        }
    }

    /// Re-fetches both subscriptions and reloads the running tunnel with the new nodes (it probes again after).
    func refreshSubscriptions() async {
        guard mock == nil, connected, let s = manager?.connection as? NETunnelProviderSession else { return }
        working = true
        defer { working = false }
        do {
            let cfg = try await buildConfig()
            let msg = try JSONSerialization.data(withJSONObject: ["reload": cfg])
            try s.sendProviderMessage(msg) { _ in }
        } catch { message = "Refresh failed: \(error.localizedDescription)" }
    }

    func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stopPolling() { poller?.cancel(); poller = nil }

    func refresh() async {
        guard let ch = channel else { return }
        do {
            let r = try await ch.call(ClashCall.proxies)
            guard r.status == 200 else { apiError = "Clash API: HTTP \(r.status) \(r.body.prefix(120))"; return }
            let new = try ProxyState.parse(Data(r.body.utf8))
            if new != state { state = new }      // no re-render (and no accessibility churn) when nothing changed
            if apiError != nil { apiError = nil }
        } catch { apiError = "Clash API: \(error.localizedDescription)" }
        if mock == nil, let p = provider, let new = try? await p.probe(now: false), new != probe { probe = new }
    }

    /// Probes the network again and applies the result (the extension does it by itself on every network change).
    /// Test mode: the app probes from the simulator (or takes PROXY_MOCK_PROBE) and flips the selectors itself,
    /// as the extension would.
    func recheckNetwork() async {
        probing = true
        defer { probing = false }
        if let mock {
            let r: ProbeResult
            if let spec = mockProbe { r = ProbeResult.mock(spec) } else { r = await NetworkProbe.run() }
            for req in ClashCall.apply(r) { _ = try? await mock.call(req) }
            probe = r
        } else if let p = provider {
            probe = (try? await p.probe(now: true)) ?? probe
        }
        await refresh()
    }

    /// Delay-tests every group's candidates (twice: the second run reuses each node's warm session where the
    /// protocol allows, which is what the numbers show), then checks where each group actually exits.
    func runTest() async {
        guard let ch = channel, let state else { return }
        testing = true
        defer { testing = false }
        for _ in 0..<2 {
            await withTaskGroup(of: Void.self) { g in
                for grp in state.groups {
                    let test = grp.directAllowed ? Plan.group(grp.tag)!.allTest : Plan.group(grp.tag)!.nodesTest
                    g.addTask { _ = try? await ch.call(ClashCall.test(test)) }
                }
            }
        }
        await refresh()
        let start = Date()
        async let cn = exitOf("https://myip.ipip.net", china: true)
        async let intl = exitOf("https://www.cloudflare.com/cdn-cgi/trace")
        async let ai = exitOf("https://claude.ai/cdn-cgi/trace")
        let (c, i, a) = await (cn, intl, ai)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        testLines = [fmt.string(from: start), "China exit: \(c)", "International exit: \(i)", "AI exit (claude.ai): \(a)"]
    }

    /// Where a request through the tunnel exits: the country (and mainland region) only, never the IP.
    private func exitOf(_ link: String, china: Bool = false) async -> String {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        if let (h, p) = mockHTTPProxy {
            cfg.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": h, "HTTPPort": p,
                                             "HTTPSEnable": 1, "HTTPSProxy": h, "HTTPSPort": p]
        }
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        let t = Date()
        var req = URLRequest(url: URL(string: link)!)
        req.setValue("curl/8.7.1", forHTTPHeaderField: "User-Agent")
        guard let (d, _) = try? await session.data(for: req) else { return "no answer" }
        let ms = Int(Date().timeIntervalSince(t) * 1000)
        let body = String(decoding: d, as: UTF8.self)
        let place: String?
        if china {
            let v = NetworkProbe.chinaVerdict(body)
            place = v.exit.map { v.valid ? $0 : "\($0) (not mainland)" }
        } else {
            place = NetworkProbe.traceLoc(body)
        }
        guard let place else { return "no answer" }
        return "\(place), \(ms) ms for a fresh HTTPS request incl. TLS handshake"
    }
}
