import Foundation
import Libbox
import Network
import NetworkExtension
import ProxyCore

/// The packet tunnel: runs sing-box (libbox) with the config the app built from the two subscriptions.
/// Adapted from sing-box-for-apple's ExtensionProvider (GPL-3.0), trimmed to what this app needs:
/// - the config arrives in the start options ("config") or a "reload" app message, and is persisted in the
///   extension's own container, so an on-demand/system restart (no options) uses the last one;
/// - "$RULES" / "$DATA" in it become the bundled rule-set folder and the extension's data folder;
/// - the app reaches sing-box's Clash API through `handleAppMessage` ("clash" requests), which this process
///   forwards to the loopback controller, so no App Group or shared socket is needed;
/// - on start and on every network change it probes where this network's own exit lands (`NetworkProbe`; the
///   extension's own requests bypass the tunnel) and flips each group's selector between `·nodes` and `·all`
///   (nodes + direct) through the Clash API, so a network change never reloads sing-box;
/// - after every probe, every `HealthCheck.interval` seconds and on the app's request it runs the real check
///   (`HealthCheck`): each group's candidate in use must load a real page from a valid exit, else the group is
///   pinned to the fastest candidate that does.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var commandServer: LibboxCommandServer?
    private lazy var platform = PlatformInterface(self)
    private var config: String?
    private var clash: (base: URL, secret: String)?
    private var pathMonitor: NWPathMonitor?
    private var probeTask: Task<Void, Never>?
    private var lastPath: String?
    private var probe: ProbeResult?
    private var checkPorts: [String: Int] = [:]
    private var health = HealthReport()
    private var healthTask: Task<Void, Never>?
    private var healthTimer: Task<Void, Never>?
    private var healthAgain = false
    private var paused = false

    private static let fm = FileManager.default
    private static var dataDir: URL {
        let d = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("proxy", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var configFile: URL { dataDir.appendingPathComponent("config.json") }
    private static var rulesDir: String { Bundle.main.resourceURL!.appendingPathComponent("Rules").path }

    override func startTunnel(options: [String: NSObject]?) async throws {
        var cfg = options?["config"] as? String
        if cfg == nil { cfg = try? String(contentsOf: Self.configFile, encoding: .utf8) }
        guard let cfg else { throw Self.error("no config: open the app and connect once") }
        try? cfg.write(to: Self.configFile, atomically: true, encoding: .utf8)

        let setup = LibboxSetupOptions()
        setup.basePath = Self.dataDir.path
        setup.workingPath = Self.dataDir.path
        setup.tempPath = NSTemporaryDirectory()
        // a loopback TCP port instead of the default unix socket, whose path in an extension container can exceed
        // the 104-byte sun_path limit
        setup.commandServerListenPort = 9091
        setup.commandServerSecret = UUID().uuidString
        setup.logMaxLines = 300
        setup.oomKillerEnabled = true
        setup.crashReportSource = "PacketTunnel"
        var err: NSError?
        LibboxSetup(setup, &err)
        if let err { throw Self.error("setup: \(err.localizedDescription)") }

        commandServer = LibboxNewCommandServer(platform, platform, &err)
        if let err { throw Self.error("command server: \(err.localizedDescription)") }
        try commandServer!.start()
        try startService(cfg)
        await startPathMonitor()
    }

    // MARK: network detection

    @MainActor private func startPathMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            // the tunnel's own interface changes the path too; key on the physical interfaces and their status
            let key = "\(path.status)|" + path.availableInterfaces.filter { $0.type != .other }.map { "\($0.type):\($0.name)" }.joined(separator: ",")
            Task { await self?.pathChanged(key) }
        }
        m.start(queue: DispatchQueue(label: "path"))
        pathMonitor = m
        reprobe(after: 0)
        startHealthTimer()
    }

    @MainActor private func pathChanged(_ key: String) {
        guard key != lastPath else { return }
        let first = lastPath == nil
        lastPath = key
        if !first { reprobe(after: 2) }   // debounce: Wi-Fi joins and DHCP settle
    }

    @MainActor private func reprobe(after seconds: UInt64) {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let r = await NetworkProbe.run()
            guard !Task.isCancelled else { return }
            await self.apply(r)
        }
    }

    @MainActor private func apply(_ r: ProbeResult) async {
        probe = r
        // connections opened on the old network's choice are cut by the selectors (interrupt_exist_connections)
        for req in ClashCall.apply(r) {
            for attempt in 0..<5 {
                if (200..<300).contains(await clashCall(req).status) { break }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)   // sing-box still starting
            }
        }
        // no probe answered at all: the network was probably still coming up, so look again shortly
        if r.verdicts.values.allSatisfy({ $0.exit == nil }) { reprobe(after: 10) }
        runHealth()
    }

    // MARK: the real check

    private var directAllowed: [String: Bool] { probe?.verdicts.mapValues(\.valid) ?? [:] }

    /// Starts a round, or queues one more right after the round in progress (rounds never overlap: they share the
    /// check selectors).
    @MainActor private func runHealth() {
        guard healthTask == nil else { healthAgain = true; return }
        let ports = checkPorts
        guard !ports.isEmpty else { return }
        healthTask = Task { [weak self] in
            guard let self else { return }
            let checker = HealthCheck(call: { await self.clashCall($0) }, load: { await HealthCheck.load(group: $0, port: $1) },
                                      ports: ports)
            let r = await checker.run(directAllowed: await MainActor.run { self.directAllowed })
            await MainActor.run {
                if !r.entries.isEmpty { self.health = r }
                self.healthTask = nil
                if self.healthAgain { self.healthAgain = false; self.runHealth() }
            }
        }
    }

    @MainActor private func startHealthTimer() {
        healthTimer?.cancel()
        healthTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: HealthCheck.interval * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if await MainActor.run(body: { !self.paused }) { await self.runHealth() }
            }
        }
    }

    private func startService(_ cfg: String) throws {
        let resolved = cfg.replacingOccurrences(of: "$RULES", with: Self.rulesDir)
            .replacingOccurrences(of: "$DATA", with: Self.dataDir.path)
        config = cfg
        clash = Self.clashEndpoint(resolved)
        checkPorts = HealthCheck.ports(config: resolved)
        do {
            try commandServer!.startOrReloadService(resolved, options: LibboxOverrideOptions())
        } catch {
            throw Self.error("start: \(error.localizedDescription)")
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        await MainActor.run {
            self.pathMonitor?.cancel(); self.pathMonitor = nil; self.probeTask?.cancel()
            self.healthTimer?.cancel(); self.healthTask?.cancel()
        }
        try? commandServer?.closeService()
        platform.reset()
        try? await Task.sleep(nanoseconds: 100_000_000)
        commandServer?.close()
        commandServer = nil
    }

    override func sleep() async {
        await MainActor.run { paused = true }
        commandServer?.pause()
    }
    override func wake() {
        commandServer?.wake()
        Task { @MainActor in paused = false; runHealth() }
    }

    // MARK: app messages: {"clash": {method, path, body}} -> {status, body};  {"reload": "<config>"} -> {status};
    //                    {"probe": false} -> the last probe (ProbeResult JSON) / {"probe": true} -> probe now
    //                    {"health": false} -> the last real check (HealthReport JSON) / {"health": true} -> check now

    override func handleAppMessage(_ data: Data) async -> Data? {
        struct Message: Decodable { let clash: ClashRequest?; let reload: String?; let probe: Bool?; let health: Bool? }
        struct ClashRequest: Decodable { let method: String; let path: String; let body: String? }
        struct Reply: Encodable { let status: Int; let body: String }
        func reply(_ s: Int, _ b: String) -> Data? { try? JSONEncoder().encode(Reply(status: s, body: b)) }

        guard let msg = try? JSONDecoder().decode(Message.self, from: data) else { return reply(400, "bad message") }
        if let cfg = msg.reload {
            do {
                try? cfg.write(to: Self.configFile, atomically: true, encoding: .utf8)
                reasserting = true
                defer { reasserting = false }
                try startService(cfg)
                await reprobe(after: 1)   // the new sing-box starts from the selectors' defaults
                return reply(200, "reloaded")
            } catch { return reply(500, error.localizedDescription) }
        }
        if let now = msg.probe {
            if now {
                let r = await NetworkProbe.run()
                await apply(r)
            }
            guard let p = await MainActor.run(body: { self.probe }), let d = try? JSONEncoder().encode(p) else { return reply(204, "") }
            return reply(200, String(decoding: d, as: UTF8.self))
        }
        if let now = msg.health {
            if now {
                await runHealth()
                while await MainActor.run(body: { self.healthTask != nil }) { try? await Task.sleep(nanoseconds: 200_000_000) }
            }
            guard let d = try? JSONEncoder().encode(await MainActor.run { self.health }) else { return reply(500, "") }
            return reply(200, String(decoding: d, as: UTF8.self))
        }
        guard let r = msg.clash else { return reply(400, "bad message") }
        let resp = await clashCall(ClashCall.Request(method: r.method, path: r.path, body: r.body))
        return reply(resp.status, resp.body)
    }

    private func clashCall(_ r: ClashCall.Request) async -> ClashCall.Response {
        guard let clash, let url = URL(string: r.path, relativeTo: clash.base) else {
            return .init(status: 503, body: "sing-box not running")
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = r.method
        req.setValue("Bearer \(clash.secret)", forHTTPHeaderField: "Authorization")
        if let b = r.body { req.httpBody = Data(b.utf8); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (body, resp) = try await URLSession.shared.data(for: req)
            return .init(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: String(decoding: body, as: UTF8.self))
        } catch { return .init(status: 502, body: error.localizedDescription) }
    }

    private static func clashEndpoint(_ cfg: String) -> (URL, String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(cfg.utf8)) as? [String: Any],
              let api = (obj["experimental"] as? [String: Any])?["clash_api"] as? [String: Any],
              let ctl = api["external_controller"] as? String, let base = URL(string: "http://\(ctl)") else { return nil }
        return (base, api["secret"] as? String ?? "")
    }

    func writeMessage(_ message: String) { commandServer?.writeMessage(2, message: message) }

    static func error(_ s: String) -> NSError {
        NSError(domain: "PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: s])
    }
}
