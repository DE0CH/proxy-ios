import Foundation
import ProxyCore

/// Fetches the two airport subscriptions as sing-box JSON. Each one falls back to the last good copy (kept in
/// Application Support), then to the snapshot bundled at build time, so the first connect works even where an
/// airport's subscription host is blocked without a proxy. The China node (our own Guangzhou server) has no
/// subscription URL: it is only the copy bundled at build time (repo secret CN_NODE_JSON).
enum Subscriptions {
    static let userAgent = "SFI/1.12.0 (sing-box 1.12.0)"

    struct Result {
        var data: [Plan.Source: Data] = [:]
        var notes: [String] = []      // e.g. "良心云: cached copy (fetch failed: …)"
    }

    static var cacheDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("subscriptions", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func url(_ a: Plan.Source) -> URL? {
        let s: String
        switch a {
        case .liangxin: s = Secrets.liangxinSubscription
        case .gulu: s = Secrets.guluSubscription
        case .cn: return nil
        }
        return s.isEmpty ? nil : URL(string: s)
    }

    static func name(_ a: Plan.Source) -> String { a.name }

    static func valid(_ d: Data, _ a: Plan.Source) -> Bool { (try? ConfigBuilder.nodes(from: d, source: a))?.isEmpty == false }

    static func bundled(_ a: Plan.Source) -> Data? {
        guard let b = Bundle.main.url(forResource: a.rawValue, withExtension: "json", subdirectory: "Subscriptions"),
              let c = try? Data(contentsOf: b), valid(c, a) else { return nil }
        return c
    }

    static func fetchAll() async -> Result {
        var r = Result()
        if let c = bundled(.cn) { r.data[.cn] = c } else { r.notes.append("China node: not in this build") }
        await withTaskGroup(of: (Plan.Source, Data?, String?).self) { g in
            for a in Plan.Source.allCases where a != .cn {
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
                } else if let c = bundled(a) {
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
