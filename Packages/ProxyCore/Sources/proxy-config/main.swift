import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ProxyCore

// proxy-config: runs the app's ConfigBuilder on a desktop, for end-to-end tests with a desktop sing-box.
// Usage: proxy-config --liangxin FILE --gulu FILE [--cn FILE] --rules DIR --data DIR --secret S [--mixed PORT]
//                     [--controller HOST:PORT] [--check-port-base PORT]
//        proxy-config --probe        (the network probe from this machine: verdicts and countries only, no IPs)
//        proxy-config --health --controller HOST:PORT --secret S [--check-port-base PORT] [--direct China=0,…]
//                                    (one round of the real check against a running sing-box: the extension's logic,
//                                     pages loaded with curl through the check ports; verdicts, node names, countries)
// Prints the config JSON on stdout and the per-group node counts / warnings on stderr (never node secrets).
var args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
if args.contains("--probe") {
    let r = await NetworkProbe.run()
    for g in Plan.groups {
        let v = r.verdicts[g.tag]
        print("\(g.tag): direct \(v?.valid == true ? "valid" : "invalid") (exit \(v?.exit ?? "no answer"))")
    }
    exit(0)
}
if args.contains("--health") {
    let ctl = opt("--controller") ?? "127.0.0.1:9090", secret = opt("--secret") ?? ""
    let base = Int(opt("--check-port-base") ?? "") ?? BuildOptions(clashSecret: "").checkPortBase
    var ports: [String: Int] = [:]
    for (i, g) in Plan.groups.enumerated() { ports[g.tag] = base + i }
    let direct = ProbeResult.mock(opt("--direct") ?? "").verdicts.mapValues(\.valid)
    let check = HealthCheck(call: { r in
        var req = URLRequest(url: URL(string: "http://\(ctl)\(r.path)")!, timeoutInterval: 30)
        req.httpMethod = r.method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let b = r.body { req.httpBody = Data(b.utf8); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        guard let (d, resp) = try? await URLSession.shared.data(for: req) else { return .init(status: 0, body: "") }
        return .init(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: String(decoding: d, as: UTF8.self))
    }, load: { group, port in
        let t = Date()
        let v = await NetworkProbe.verdict(group) { u in curlGet(u, proxy: "http://127.0.0.1:\(port)") }
        return .init(passed: v.valid, exit: v.exit, ms: Int(Date().timeIntervalSince(t) * 1000))
    }, ports: ports)
    let r = await check.run(directAllowed: direct)
    for g in Plan.groups {
        guard let e = r.entries[g.tag] else { print("\(g.tag): no state"); continue }
        let name = e.candidate.map { ProxyState.Candidate.displayName($0) } ?? "–"
        print("\(g.tag): \(e.passed ? "passed" : "FAILED") \(e.pinned ? "pinned " : "")\(name) (exit \(e.exit ?? "none"), \(e.ms.map { "\($0) ms" } ?? "–"); \(e.failed.count) failed)")
    }
    exit(r.entries.values.allSatisfy { $0.passed } ? 0 : 2)
}

/// GET through a proxy with curl (Foundation on Linux ignores a session's proxy settings); body of a 200, else nil.
func curlGet(_ u: URL, proxy: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["curl", "-fsS", "-m", "10", "-A", "curl/8.7.1", "-x", proxy, u.absoluteString]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? String(decoding: d, as: UTF8.self) : nil
}

var subs: [Plan.Source: Data] = [:]
if let f = opt("--liangxin") { subs[.liangxin] = FileManager.default.contents(atPath: f) }
if let f = opt("--gulu") { subs[.gulu] = FileManager.default.contents(atPath: f) }
if let f = opt("--cn") { subs[.cn] = FileManager.default.contents(atPath: f) }
var o = BuildOptions(clashSecret: opt("--secret") ?? "test")
if let r = opt("--rules") { o.rulesDir = r }
if let d = opt("--data") { o.dataDir = d }
if let p = opt("--mixed"), let port = Int(p) { o.inbound = .mixed(port: port) }
if let c = opt("--controller") { o.clashController = c }
if let b = opt("--check-port-base"), let port = Int(b) { o.checkPortBase = port }
do {
    let r = try ConfigBuilder.build(subscriptions: subs, options: o)
    for g in Plan.groups { FileHandle.standardError.write(Data("\(g.tag): \(r.groups[g.tag]?.count ?? 0) nodes\n".utf8)) }
    for w in r.warnings { FileHandle.standardError.write(Data("warning: \(w)\n".utf8)) }
    print(r.json)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1)
}
