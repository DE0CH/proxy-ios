import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where this network's own exit lands for each group, measured with direct requests (in the packet tunnel the
/// extension's own traffic bypasses the tunnel, so these see the network as it is: a plain line, or a router that
/// already splits China / international / AI). Direct is a valid candidate of a group only when its probe answers
/// from a valid place; a probe that fails makes direct invalid. Only countries/regions are kept, never IPs.
public struct ProbeResult: Codable, Equatable {
    public struct Verdict: Codable, Equatable {
        public let valid: Bool
        public let exit: String?     // e.g. "CN 广东", "HK", "US"; nil = no answer
        public init(valid: Bool, exit: String?) { self.valid = valid; self.exit = exit }
    }
    public let verdicts: [String: Verdict]   // group tag -> verdict for going direct
    public let at: Date
    public init(verdicts: [String: Verdict], at: Date = Date()) { self.verdicts = verdicts; self.at = at }

    /// The selector choice per group: `·all` (direct races the nodes) when direct is valid here, else `·nodes`.
    public var selections: [(group: String, member: String)] {
        Plan.groups.map { g in (g.tag, verdicts[g.tag]?.valid == true ? g.allTest : g.nodesTest) }
    }

    /// PROXY_MOCK_PROBE for the simulator replica, e.g. "China=0,International=1,AI=1".
    public static func mock(_ spec: String) -> ProbeResult {
        var v: [String: Verdict] = [:]
        for part in spec.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { v[kv[0]] = Verdict(valid: kv[1] == "1", exit: "mock") }
        }
        return ProbeResult(verdicts: v)
    }
}

public enum NetworkProbe {
    public static let chinaURL = URL(string: "https://myip.ipip.net")!
    public static let intlURL = URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!
    public static let aiURLs = [URL(string: "https://claude.ai/cdn-cgi/trace")!, URL(string: "https://chatgpt.com/cdn-cgi/trace")!]

    /// `loc=` of a Cloudflare trace.
    public static func traceLoc(_ body: String) -> String? {
        for line in body.split(separator: "\n") where line.hasPrefix("loc=") {
            let v = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        return nil
    }

    /// myip.ipip.net answers "当前 IP：<ip>  来自于：<country> <region> <city>  <carrier>"; returns (country, region).
    public static func ipipPlace(_ body: String) -> (country: String, region: String?)? {
        guard let r = body.range(of: "来自于：") ?? body.range(of: "来自于:") else { return nil }
        let words = body[r.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard let c = words.first else { return nil }
        return (c, words.count > 1 ? words[1] : nil)
    }

    static let notMainland: Set<String> = ["香港", "澳门", "澳門", "台湾", "台灣"]

    public static func chinaVerdict(_ body: String?) -> ProbeResult.Verdict {
        guard let body, let p = ipipPlace(body) else { return .init(valid: false, exit: nil) }
        let mainland = p.country == "中国" && !(p.region.map(notMainland.contains) ?? false)
        let label = p.country == "中国" ? (mainland ? "CN \(p.region ?? "")".trimmingCharacters(in: .whitespaces) : p.region ?? "中国") : p.country
        return .init(valid: mainland, exit: label)
    }

    public static func intlVerdict(_ body: String?) -> ProbeResult.Verdict {
        guard let loc = body.flatMap(traceLoc) else { return .init(valid: false, exit: nil) }
        return .init(valid: loc != "CN", exit: loc)
    }

    public static func aiVerdict(_ body: String?) -> ProbeResult.Verdict {
        guard let loc = body.flatMap(traceLoc) else { return .init(valid: false, exit: nil) }
        return .init(valid: !["CN", "HK", "MO"].contains(loc), exit: loc)
    }

    /// Runs the three probes in parallel with `session` (a direct, uncached session), 6 s each.
    public static func run(session: URLSession = .init(configuration: .ephemeral)) async -> ProbeResult {
        @Sendable func get(_ u: URL) async -> String? {
            var req = URLRequest(url: u, timeoutInterval: 6)
            req.setValue("curl/8.7.1", forHTTPHeaderField: "User-Agent")   // ipip.net answers plain text to curl
            guard let (d, resp) = try? await session.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return String(decoding: d, as: UTF8.self)
        }
        async let cn = get(chinaURL)
        async let intl = get(intlURL)
        async let ai: String? = {
            for u in aiURLs { if let b = await get(u), traceLoc(b) != nil { return b } }
            return nil
        }()
        let (c, i, a) = await (cn, intl, ai)
        return ProbeResult(verdicts: [Plan.china: chinaVerdict(c), Plan.intl: intlVerdict(i), Plan.ai: aiVerdict(a)])
    }
}
