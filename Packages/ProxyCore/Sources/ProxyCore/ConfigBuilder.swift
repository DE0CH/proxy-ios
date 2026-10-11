import Foundation

/// The routing plan, the same as openwrt-main's OpenClash split:
///   China (geosite-cn / geoip-cn) and private ranges -> direct
///   AI (geosite category-ai-!cn)                      -> selector "AI"   = 良心云SG | 咕噜SG
///   everything else                                    -> selector "国际" = 咕噜HK | 良心云HK
/// Each region group is a selector of [its Auto urltest, every node], so a node is either picked automatically
/// (Auto: lowest delay, kept unless another is better by `tolerance`) or pinned by selecting it.
public enum Plan {
    public static let intl = "国际"
    public static let ai = "AI"
    public static let autoSuffix = "·Auto"

    public struct Region: Hashable {
        public let group: String      // selector tag, e.g. "咕噜HK"
        public let label: String      // shown in the UI, e.g. "咕噜云 HK"
        public let airport: Airport
        public let match: String      // node-name regex inside that airport
        public var auto: String { group + Plan.autoSuffix }
    }

    public enum Airport: String, CaseIterable {
        case liangxin, gulu
        /// Prefix put in front of every node tag so the two airports' tags never clash.
        public var prefix: String { self == .liangxin ? "良心云 " : "咕噜 " }
    }

    public static let guluHK = Region(group: "咕噜HK", label: "咕噜云 HK", airport: .gulu, match: "香港.*x3|x3.*香港")
    public static let liangxinHK = Region(group: "良心云HK", label: "良心云 HK", airport: .liangxin, match: "香港")
    public static let liangxinSG = Region(group: "良心云SG", label: "良心云 SG", airport: .liangxin, match: "新加坡")
    public static let guluSG = Region(group: "咕噜SG", label: "咕噜云 SG", airport: .gulu, match: "新加坡.*x3|x3.*新加坡")

    /// The two switches and their choices, in display order (the first choice is the default).
    public static let switches: [(tag: String, title: String, choices: [Region])] = [
        (intl, "International", [guluHK, liangxinHK]),
        (ai, "AI apps", [liangxinSG, guluSG]),
    ]
    public static var regions: [Region] { switches.flatMap { $0.choices } }

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
    public var urlTestURL = "http://www.gstatic.com/generate_204"
    public var urlTestInterval = "1m"
    public var urlTestTolerance = 150
    public var logLevel = "warn"
    public init(clashSecret: String) { self.clashSecret = clashSecret }
}

public struct BuildResult {
    public let json: String
    public let regions: [Plan.Region: [String]]   // region -> node tags (as in the config)
    public let warnings: [String]
}

public enum ConfigError: Error, CustomStringConvertible {
    case badSubscription(Plan.Airport, String)
    case noNodes
    public var description: String {
        switch self {
        case let .badSubscription(a, why): return "\(a.rawValue) subscription: \(why)"
        case .noNodes: return "no usable HK/SG nodes in either subscription"
        }
    }
}

public enum ConfigBuilder {
    /// Proxy outbounds of a sing-box subscription (the JSON the airports serve to UA "SFI/…").
    public static func nodes(from data: Data, airport: Plan.Airport) throws -> [[String: Any]] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.badSubscription(airport, "not a JSON object")
        }
        guard let outs = obj["outbounds"] as? [[String: Any]] else {
            throw ConfigError.badSubscription(airport, "no outbounds")
        }
        return outs.filter { o in
            guard let type = o["type"] as? String, Plan.proxyTypes.contains(type),
                  let tag = o["tag"] as? String, o["server"] != nil else { return false }
            return Plan.infoTags.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) == nil
        }
    }

    static func matches(_ tag: String, _ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) != nil
    }

    /// Builds the full config. `subscriptions` maps each airport to its subscription JSON; a missing airport just
    /// leaves its regions out (the switches then offer only what exists).
    public static func build(subscriptions: [Plan.Airport: Data], options: BuildOptions) throws -> BuildResult {
        var warnings: [String] = []
        var regionNodes: [Plan.Region: [String]] = [:]
        var nodeOutbounds: [[String: Any]] = []
        var seen = Set<String>()
        for airport in Plan.Airport.allCases {
            guard let data = subscriptions[airport] else { warnings.append("\(airport.rawValue): no subscription"); continue }
            let nodes: [[String: Any]]
            do { nodes = try ConfigBuilder.nodes(from: data, airport: airport) } catch { warnings.append("\(error)"); continue }
            for region in Plan.regions where region.airport == airport {
                var tags: [String] = []
                for var n in nodes {
                    let raw = n["tag"] as! String
                    guard matches(raw, region.match) else { continue }
                    let tag = airport.prefix + raw
                    tags.append(tag)
                    if seen.insert(tag).inserted {
                        n["tag"] = tag
                        n.removeValue(forKey: "domain_resolver")   // the airports name their own DNS server; ours is "cn"
                        n.removeValue(forKey: "detour")
                        nodeOutbounds.append(n)
                    }
                }
                if tags.isEmpty { warnings.append("\(region.group): no nodes") } else { regionNodes[region] = tags }
            }
        }
        guard !regionNodes.isEmpty else { throw ConfigError.noNodes }

        var outbounds: [[String: Any]] = []
        for sw in Plan.switches {
            let choices = sw.choices.filter { regionNodes[$0] != nil }.map(\.group)
            // a switch whose regions are all missing falls back to the other switch's groups, never to direct
            let members = choices.isEmpty ? Plan.regions.filter { regionNodes[$0] != nil }.map(\.group) : choices
            outbounds.append(["type": "selector", "tag": sw.tag, "outbounds": members, "default": members[0],
                              "interrupt_exist_connections": true])
        }
        for region in Plan.regions {
            guard let tags = regionNodes[region] else { continue }
            outbounds.append(["type": "selector", "tag": region.group, "outbounds": [region.auto] + tags,
                              "default": region.auto, "interrupt_exist_connections": true])
            outbounds.append(["type": "urltest", "tag": region.auto, "outbounds": tags, "url": options.urlTestURL,
                              "interval": options.urlTestInterval, "tolerance": options.urlTestTolerance])
        }
        outbounds += nodeOutbounds
        outbounds.append(["type": "direct", "tag": "direct"])

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
                    ["type": "udp", "tag": "cn", "server": "223.5.5.5"],
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
                    ["rule_set": ["geosite-cn", "geoip-cn"], "outbound": "direct"],
                ],
                "rule_set": ruleSets,
                "final": Plan.intl,
                "auto_detect_interface": true,
                "default_domain_resolver": ["server": "cn"],
            ] as [String: Any],
            "experimental": [
                "cache_file": ["enabled": true, "path": "\(options.dataDir)/cache.db"],
                "clash_api": ["external_controller": options.clashController, "secret": options.clashSecret],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        return BuildResult(json: String(decoding: data, as: UTF8.self), regions: regionNodes, warnings: warnings)
    }
}
