import Foundation
import ProxyCore

/// Fetches the two airport subscriptions as sing-box JSON. Each one falls back to the last good copy (kept in
/// Application Support), then to the snapshot bundled at build time, so the first connect works even where an
/// airport's subscription host is blocked without a proxy.
enum Subscriptions {
    static let userAgent = "SFI/1.12.0 (sing-box 1.12.0)"

    struct Result {
        var data: [Plan.Airport: Data] = [:]
        var notes: [String] = []      // e.g. "良心云: cached copy (fetch failed: …)"
    }

    static var cacheDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("subscriptions", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func url(_ a: Plan.Airport) -> URL? {
        let s = a == .liangxin ? Secrets.liangxinSubscription : Secrets.guluSubscription
        return s.isEmpty ? nil : URL(string: s)
    }

    static func name(_ a: Plan.Airport) -> String { a == .liangxin ? "良心云" : "咕噜云" }

    static func valid(_ d: Data, _ a: Plan.Airport) -> Bool { (try? ConfigBuilder.nodes(from: d, airport: a))?.isEmpty == false }

    static func fetchAll() async -> Result {
        var r = Result()
        await withTaskGroup(of: (Plan.Airport, Data?, String?).self) { g in
            for a in Plan.Airport.allCases {
                g.addTask {
                    guard let u = url(a) else { return (a, nil, "no subscription URL in this build") }
                    var req = URLRequest(url: u, timeoutInterval: 20)
                    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                    do {
                        let (d, resp) = try await URLSession.shared.data(for: req)
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        guard code == 200, valid(d, a) else { return (a, nil, "HTTP \(code), not a sing-box profile") }
                        return (a, d, nil)
                    } catch { return (a, nil, error.localizedDescription) }
                }
            }
            for await (a, d, why) in g {
                let cache = cacheDir.appendingPathComponent("\(a.rawValue).json")
                if let d {
                    try? d.write(to: cache, options: .atomic)
                    r.data[a] = d
                } else if let c = try? Data(contentsOf: cache), valid(c, a) {
                    r.data[a] = c
                    r.notes.append("\(name(a)): last good copy (fetch failed: \(why ?? "?"))")
                } else if let b = Bundle.main.url(forResource: a.rawValue, withExtension: "json", subdirectory: "Subscriptions"),
                          let c = try? Data(contentsOf: b), valid(c, a) {
                    r.data[a] = c
                    r.notes.append("\(name(a)): copy from the build (fetch failed: \(why ?? "?"))")
                } else {
                    r.notes.append("\(name(a)): unavailable (\(why ?? "?"))")
                }
            }
        }
        return r
    }
}
