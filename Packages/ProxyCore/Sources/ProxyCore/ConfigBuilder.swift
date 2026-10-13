import Foundation

/// The routing plan: three groups, each "the fastest valid candidate", where going direct is one candidate like any
/// node and is valid only when this network's own exit already lands in the right place:
///   China (geosite-cn / geoip-cn)       candidates: the China node(s), direct   valid: exits in mainland China
///   AI (geosite category-ai-!cn)        candidates: airport nodes, direct       valid: exits outside mainland China and HK
///   International (everything else)     candidates: airport nodes, direct       valid: exits outside mainland China
/// Node validity is known from the node's name (region); direct's validity is measured by `NetworkProbe` on every
/// network change. Each group is a selector of two urltests, `<group>·nodes` and `<group>·all` (= nodes + direct);
/// the probe's verdict picks one, so a network change never reloads sing-box.
public enum Plan {
    public static let china = "China"
    public static let intl = "International"
    public static let ai = "AI"
    public static let nodesSuffix = "·nodes"
    public static let allSuffix = "·all"
    public static let directPrefix = "direct·"

    public struct Group: Hashable {
        public let tag: String
        public let title: String
        public let testURL: String
        public var nodesTest: String { tag + Plan.nodesSuffix }
        public var allTest: String { tag + Plan.allSuffix }
        /// The direct outbound this group races (one per group, so each keeps its own delay history and test URL).
        public var direct: String { Plan.directPrefix + tag }
    }

    /// Display order. China's delay is measured to a mainland URL; the others to gstatic (unreachable from a
    /// mainland exit, so an invalid candidate also measures as a timeout there).
    public static let groups: [Group] = [
        Group(tag: china, title: "China", testURL: "http://connect.rom.miui.com/generate_204"),
        Group(tag: intl, title: "International", testURL: "http://www.gstatic.com/generate_204"),
        Group(tag: ai, title: "AI", testURL: "http://www.gstatic.com/generate_204"),
    ]
    public static func group(_ tag: String) -> Group? { groups.first { $0.tag == tag } }

    public enum Source: String, CaseIterable {
        case liangxin, gulu, cn
        /// Prefix put in front of every node tag so the sources' tags never clash.
        public var prefix: String {
            switch self {
            case .liangxin: return "良心云 "
            case .gulu: return "咕噜 "
            case .cn: return "回国 "
            }
        }
        public var name: String {
            switch self {
            case .liangxin: return "良心云"
            case .gulu: return "咕噜云"
            case .cn: return "China node"
            }
        }
        /// Nodes of this source that are used at all (咕噜云: only its x3 lines, as on the router).
        var keep: String? { self == .gulu ? "x3" : nil }
    }

    /// Node names that exit in mainland China (an airport's 回国 nodes); never International or AI candidates.
    static let mainland = "回国|大陆|内地|🇨🇳|中国(?!香港|澳门|澳門|台湾|台灣)"
    /// Node names AI services refuse besides the mainland: Hong Kong and Macau.
    static let aiRefused = "香港|🇭🇰|(?i:\\bHK\\b|hong ?kong)|澳门|澳門|🇲🇴|(?i:macau|macao)"

    /// Tags in a subscription that are labels, not servers.
    static let infoTags = try! NSRegularExpression(pattern: "剩余|套餐|到期|官网|流量|重置")
    static let proxyTypes: Set<String> = ["vless", "vmess", "trojan", "shadowsocks", "anytls", "hysteria2",
                                         "hysteria", "tuic", "naive", "shadowtls", "wireguard", "socks", "http"]
}

public enum InboundMode: Equatable {
    case tun
    case mixed(port: Int)   // desktop testing: a local SOCKS/HTTP port instead of the iOS tun
}

public struct BuildOptions {
    public var inbound: InboundMode = .tun
    public var rulesDir: String = "$RULES"      // the extension replaces it with its bundle's Rules folder
    public var dataDir: String = "$DATA"        // the extension replaces it with its container folder
    public var clashController = "127.0.0.1:9090"
    public var clashSecret: String
    public var urlTestInterval = "1m"
    public var urlTestTolerance = 50
    public var logLevel = "warn"
    public init(clashSecret: String) { self.clashSecret = clashSecret }
}

public struct BuildResult {
    public let json: String
    public let groups: [String: [String]]   // group tag -> node candidates (direct not included)
    public let warnings: [String]
}

public enum ConfigError: Error, CustomStringConvertible {
    case badSubscription(Plan.Source, String)
    case noNodes
    public var description: String {
        switch self {
        case let .badSubscription(s, why): return "\(s.name): \(why)"
        case .noNodes: return "no usable nodes in any subscription"
        }
    }
}

public enum ConfigBuilder {
    /// Proxy outbounds of a sing-box subscription (the JSON the airports serve to UA "SFI/…").
    public static func nodes(from data: Data, source: Plan.Source) throws -> [[String: Any]] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.badSubscription(source, "not a JSON object")
        }
        guard let outs = obj["outbounds"] as? [[String: Any]] else {
            throw ConfigError.badSubscription(source, "no outbounds")
        }
        return outs.filter { o in
            guard let type = o["type"] as? String, Plan.proxyTypes.contains(type),
                  let tag = o["tag"] as? String, o["server"] != nil else { return false }
            if let k = source.keep, !tag.contains(k) { return false }
            return Plan.infoTags.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) == nil
        }
    }

    static func matches(_ tag: String, _ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) != nil
    }

    /// Which groups a node (by its name in the subscription) is a candidate for.
    static func groups(of raw: String, source: Plan.Source) -> [String] {
        if source == .cn || matches(raw, Plan.mainland) { return [Plan.china] }
        return matches(raw, Plan.aiRefused) ? [Plan.intl] : [Plan.intl, Plan.ai]
    }

    /// Builds the full config. `subscriptions` maps each source to its sing-box JSON; a missing source just leaves
    /// its nodes out. A group with no node candidates races direct alone.
    public static func build(subscriptions: [Plan.Source: Data], options: BuildOptions) throws -> BuildResult {
        var warnings: [String] = []
        var groupNodes: [String: [String]] = [:]
        var nodeOutbounds: [[String: Any]] = []
        for source in Plan.Source.allCases {
            guard let data = subscriptions[source] else { warnings.append("\(source.name): no subscription"); continue }
            let nodes: [[String: Any]]
            do { nodes = try ConfigBuilder.nodes(from: data, source: source) } catch { warnings.append("\(error)"); continue }
            for var n in nodes {
                let raw = n["tag"] as! String
                let tag = source.prefix + raw
                guard !nodeOutbounds.contains(where: { $0["tag"] as? String == tag }) else { continue }
                n["tag"] = tag
                n.removeValue(forKey: "domain_resolver")   // the airports name their own DNS server; ours is "local"
                n.removeValue(forKey: "detour")
                nodeOutbounds.append(n)
                for g in groups(of: raw, source: source) { groupNodes[g, default: []].append(tag) }
            }
        }
        guard !nodeOutbounds.isEmpty else { throw ConfigError.noNodes }
        for g in Plan.groups where groupNodes[g.tag] == nil { warnings.append("\(g.title): no nodes, direct only") }

        var outbounds: [[String: Any]] = []
        for g in Plan.groups {
            let nodes = groupNodes[g.tag] ?? []
            // without nodes, "·nodes" would be empty: both tests then race direct alone
            let nodesMembers = nodes.isEmpty ? [g.direct] : nodes
            outbounds.append(["type": "selector", "tag": g.tag, "outbounds": [g.nodesTest, g.allTest],
                              "default": nodes.isEmpty ? g.allTest : g.nodesTest, "interrupt_exist_connections": true])
            for (tag, members) in [(g.nodesTest, nodesMembers), (g.allTest, nodes + [g.direct])] {
                outbounds.append(["type": "urltest", "tag": tag, "outbounds": members, "url": g.testURL,
                                  "interval": options.urlTestInterval, "tolerance": options.urlTestTolerance,
                                  "interrupt_exist_connections": true])
            }
        }
        outbounds += nodeOutbounds
        outbounds.append(["type": "direct", "tag": "direct"])
        for g in Plan.groups { outbounds.append(["type": "direct", "tag": g.direct]) }

        let inbound: [String: Any]
        switch options.inbound {
        case .tun:
            inbound = ["type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                       "auto_route": true, "mtu": 9000]
        case let .mixed(port):
            inbound = ["type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": port]
        }
        let ruleSets: [[String: Any]] = [("geosite-cn", "geosite-cn"), ("geoip-cn", "geoip-cn"),
                                         ("geosite-ai", "geosite-category-ai-!cn")].map { tag, file in
            ["type": "local", "tag": tag, "format": "binary", "path": "\(options.rulesDir)/\(file).srs"]
        }
        let config: [String: Any] = [
            "log": ["level": options.logLevel, "timestamp": true],
            "dns": [
                "servers": [
                    // node servers resolve with the network's own resolver, so no DNS server depends on a group
                    ["type": "local", "tag": "local"],
                    // China names resolve from China (through the China group: direct where that exits in China)
                    ["type": "udp", "tag": "cn", "server": "223.5.5.5", "detour": Plan.china],
                    ["type": "https", "tag": "remote", "server": "1.1.1.1", "detour": Plan.intl],
                ],
                "rules": [["rule_set": ["geosite-cn"], "server": "cn"]],
                "final": "remote",
                "strategy": "prefer_ipv4",
            ] as [String: Any],
            "inbounds": [inbound],
            "outbounds": outbounds,
            "route": [
                "rules": [
                    ["action": "sniff"],
                    ["protocol": "dns", "action": "hijack-dns"],
                    ["ip_is_private": true, "outbound": "direct"],
                    ["rule_set": ["geosite-ai"], "outbound": Plan.ai],
                    ["rule_set": ["geosite-cn", "geoip-cn"], "outbound": Plan.china],
                ],
                "rule_set": ruleSets,
                "final": Plan.intl,
                "auto_detect_interface": true,
                "default_domain_resolver": ["server": "local"],
            ] as [String: Any],
            "experimental": [
                "cache_file": ["enabled": true, "path": "\(options.dataDir)/cache.db"],
                "clash_api": ["external_controller": options.clashController, "secret": options.clashSecret],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        return BuildResult(json: String(decoding: data, as: UTF8.self), groups: groupNodes, warnings: warnings)
    }
}
