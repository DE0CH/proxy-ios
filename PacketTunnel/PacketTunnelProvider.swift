import Foundation
import Libbox
import NetworkExtension

/// The packet tunnel: runs sing-box (libbox) with the config the app built from the two subscriptions.
/// Adapted from sing-box-for-apple's ExtensionProvider (GPL-3.0), trimmed to what this app needs:
/// - the config arrives in the start options ("config") or a "reload" app message, and is persisted in the
///   extension's own container, so an on-demand/system restart (no options) uses the last one;
/// - "$RULES" / "$DATA" in it become the bundled rule-set folder and the extension's data folder;
/// - the app reaches sing-box's Clash API through `handleAppMessage` ("clash" requests), which this process
///   forwards to the loopback controller, so no App Group or shared socket is needed.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var commandServer: LibboxCommandServer?
    private lazy var platform = PlatformInterface(self)
    private var config: String?
    private var clash: (base: URL, secret: String)?

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
    }

    private func startService(_ cfg: String) throws {
        let resolved = cfg.replacingOccurrences(of: "$RULES", with: Self.rulesDir)
            .replacingOccurrences(of: "$DATA", with: Self.dataDir.path)
        config = cfg
        clash = Self.clashEndpoint(resolved)
        do {
            try commandServer!.startOrReloadService(resolved, options: LibboxOverrideOptions())
        } catch {
            throw Self.error("start: \(error.localizedDescription)")
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        try? commandServer?.closeService()
        platform.reset()
        try? await Task.sleep(nanoseconds: 100_000_000)
        commandServer?.close()
        commandServer = nil
    }

    override func sleep() async { commandServer?.pause() }
    override func wake() { commandServer?.wake() }

    // MARK: app messages: {"clash": {method, path, body}} -> {status, body};  {"reload": "<config>"} -> {status}

    override func handleAppMessage(_ data: Data) async -> Data? {
        struct Message: Decodable { let clash: ClashRequest?; let reload: String? }
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
                return reply(200, "reloaded")
            } catch { return reply(500, error.localizedDescription) }
        }
        guard let r = msg.clash, let clash, let url = URL(string: r.path, relativeTo: clash.base) else {
            return reply(503, "sing-box not running")
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = r.method
        req.setValue("Bearer \(clash.secret)", forHTTPHeaderField: "Authorization")
        if let b = r.body { req.httpBody = Data(b.utf8); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (body, resp) = try await URLSession.shared.data(for: req)
            return reply((resp as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: body, as: UTF8.self))
        } catch { return reply(502, error.localizedDescription) }
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
