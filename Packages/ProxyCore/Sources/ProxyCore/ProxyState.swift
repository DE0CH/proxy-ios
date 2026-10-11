import Foundation

public enum ProxyStateError: Error { case unexpectedAnswer }

/// What the UI shows, read from sing-box's Clash API `GET /proxies`.
public struct ProxyState: Equatable {
    public struct Node: Equatable, Identifiable {
        public let tag: String
        public let delay: Int?          // last test in ms; nil = never tested, 0 = failed
        public var id: String { tag }
        /// The tag without the airport prefix, for display.
        public var name: String { tag.replacingOccurrences(of: "^(良心云|咕噜) ", with: "", options: .regularExpression) }
    }
    public struct Region: Equatable, Identifiable {
        public let group: String
        public let label: String
        public let auto: Bool           // true: the Auto urltest is selected; false: a node is pinned
        public let current: String?     // the node actually in use (Auto's pick, or the pinned node)
        public let nodes: [Node]
        public var id: String { group }
    }
    public struct Switch: Equatable, Identifiable {
        public let tag: String
        public let title: String
        public let selected: String     // a region group
        public let regions: [Region]    // the choices that exist in the running config
        public var id: String { tag }
    }
    public let switches: [Switch]

    /// Parses `GET /proxies`. Regions or switches missing from the running config are left out.
    public static func parse(_ data: Data) throws -> ProxyState {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = obj["proxies"] as? [String: [String: Any]] else {
            throw ProxyStateError.unexpectedAnswer
        }
        func lastDelay(_ tag: String) -> Int? {
            guard let h = proxies[tag]?["history"] as? [[String: Any]], let last = h.last else { return nil }
            return (last["delay"] as? NSNumber)?.intValue
        }
        var switches: [Switch] = []
        for sw in Plan.switches {
            guard let s = proxies[sw.tag], let now = s["now"] as? String else { continue }
            var regions: [Region] = []
            for r in sw.choices {
                guard let g = proxies[r.group], let all = g["all"] as? [String] else { continue }
                let sel = g["now"] as? String
                let isAuto = sel == r.auto
                let current = isAuto ? proxies[r.auto]?["now"] as? String : sel
                let nodes = all.filter { $0 != r.auto }.map { Node(tag: $0, delay: lastDelay($0)) }
                regions.append(Region(group: r.group, label: r.label, auto: isAuto, current: current, nodes: nodes))
            }
            switches.append(Switch(tag: sw.tag, title: sw.title, selected: now, regions: regions))
        }
        return ProxyState(switches: switches)
    }
}

/// The Clash API calls the app makes (relayed to the extension's loopback controller).
public enum ClashCall {
    public struct Request: Codable, Equatable {
        public let method: String
        public let path: String
        public let body: String?
        public init(method: String, path: String, body: String? = nil) {
            self.method = method; self.path = path; self.body = body
        }
    }
    public struct Response: Codable, Equatable {
        public let status: Int
        public let body: String
        public init(status: Int, body: String) { self.status = status; self.body = body }
    }

    static func enc(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#|")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
    public static let proxies = Request(method: "GET", path: "/proxies")
    /// Select `member` in selector `group` (a switch choice, a pinned node, or the region's Auto).
    public static func select(_ group: String, _ member: String) -> Request {
        let body = String(decoding: try! JSONSerialization.data(withJSONObject: ["name": member]), as: UTF8.self)
        return Request(method: "PUT", path: "/proxies/\(enc(group))", body: body)
    }
    /// Delay-test every node of a region's Auto urltest with its own URL (plain-HTTP gstatic).
    public static func testRegion(_ region: Plan.Region, timeoutMs: Int = 5000) -> Request {
        Request(method: "GET", path: "/group/\(enc(region.auto))/delay?timeout=\(timeoutMs)")
    }
}
