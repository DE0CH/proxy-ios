import Foundation
import ProxyCore

// proxy-config: runs the app's ConfigBuilder on a desktop, for end-to-end tests with a desktop sing-box.
// Usage: proxy-config --liangxin FILE --gulu FILE [--cn FILE] --rules DIR --data DIR --secret S [--mixed PORT]
//        proxy-config --probe        (the network probe from this machine: verdicts and countries only, no IPs)
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
var subs: [Plan.Source: Data] = [:]
if let f = opt("--liangxin") { subs[.liangxin] = FileManager.default.contents(atPath: f) }
if let f = opt("--gulu") { subs[.gulu] = FileManager.default.contents(atPath: f) }
if let f = opt("--cn") { subs[.cn] = FileManager.default.contents(atPath: f) }
var o = BuildOptions(clashSecret: opt("--secret") ?? "test")
if let r = opt("--rules") { o.rulesDir = r }
if let d = opt("--data") { o.dataDir = d }
if let p = opt("--mixed"), let port = Int(p) { o.inbound = .mixed(port: port) }
if let c = opt("--controller") { o.clashController = c }
do {
    let r = try ConfigBuilder.build(subscriptions: subs, options: o)
    for g in Plan.groups { FileHandle.standardError.write(Data("\(g.tag): \(r.groups[g.tag]?.count ?? 0) nodes\n".utf8)) }
    for w in r.warnings { FileHandle.standardError.write(Data("warning: \(w)\n".utf8)) }
    print(r.json)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1)
}
