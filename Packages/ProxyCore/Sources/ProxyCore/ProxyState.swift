import Foundation

public enum ProxyStateError: Error { case unexpectedAnswer }

/// What the UI shows, read from sing-box's Clash API `GET /proxies`.
public struct ProxyState: Equatable {
    public struct Candidate: Equatable, Identifiable {
        public let tag: String
        public let delay: Int?          // last test in ms; nil = never tested, 0 = failed
        public var id: String { tag }
        public var isDirect: Bool { tag.hasPrefix(Plan.directPrefix) }
        /// The tag without the source prefix, for display.
        public var name: String { Self.displayName(tag) }
        public static func displayName(_ tag: String) -> String {
            tag.hasPrefix(Plan.directPrefix) ? "Direct"
                : tag.replacingOccurrences(of: "^(良心云|咕噜|回国) ", with: "", options: .regularExpression)
        }
    }
    public struct Group: Equatable, Identifiable {
        public let tag: String
        public let title: String
        public let directAllowed: Bool  // direct is available on this network: the group goes direct, no race
        public let selected: String     // the selector's own member: `direct·<g>`, `<g>·nodes` or a pinned node
        public let current: String?     // the candidate in use: direct, the urltest's pick, or the pinned node
        public let auto: String?        // the automatic choice: direct when allowed, else the urltest's pick
        public let nodesPick: String?   // the nodes' urltest pick (the fastest node), the fallback when direct fails
        public let pinned: Bool         // the selector is off its automatic member (the real check failed it)
        public let candidates: [Candidate]
        public var id: String { tag }
        public var currentCandidate: Candidate? { candidates.first { $0.tag == current } }
    }
    public let groups: [Group]

    /// Parses `GET /proxies`. Groups missing from the running config are left out. `directAllowed` (the probe's verdict
    /// per group) says whether direct is the group's automatic choice; without it, a selector on direct reads as
    /// direct allowed and anything else as nodes only.
    public static func parse(_ data: Data, directAllowed: [String: Bool] = [:]) throws -> ProxyState {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = obj["proxies"] as? [String: [String: Any]] else {
            throw ProxyStateError.unexpectedAnswer
        }
        func lastDelay(_ tag: String) -> Int? {
            guard let h = proxies[tag]?["history"] as? [[String: Any]], let last = h.last else { return nil }
            return (last["delay"] as? NSNumber)?.intValue
        }
        var groups: [Group] = []
        for g in Plan.groups {
            guard let sel = proxies[g.tag], let now = sel["now"] as? String,
                  let t = proxies[g.nodesTest], let nodes = t["all"] as? [String] else { continue }
            let nodesPick = t["now"] as? String
            let direct = directAllowed[g.tag] ?? (now == g.direct)
            let members = (direct && !nodes.contains(g.direct) ? [g.direct] : []) + nodes
            groups.append(Group(tag: g.tag, title: g.title, directAllowed: direct, selected: now,
                                current: now == g.nodesTest ? nodesPick : now, auto: direct ? g.direct : nodesPick,
                                nodesPick: nodesPick, pinned: now != g.automatic(directAllowed: direct),
                                candidates: members.map { Candidate(tag: $0, delay: lastDelay($0)) }))
        }
        return ProxyState(groups: groups)
    }
}

/// The Clash API calls the app and the extension make (the app's are relayed to the extension's loopback controller).
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
    /// Select `member` in selector `group` (the probe's `direct·<g>` / `·nodes` choice, or a pinned node).
    public static func select(_ group: String, _ member: String) -> Request {
        let body = String(decoding: try! JSONSerialization.data(withJSONObject: ["name": member]), as: UTF8.self)
        return Request(method: "PUT", path: "/proxies/\(enc(group))", body: body)
    }
    /// Delay-test one outbound (e.g. a group's direct) against `url`.
    public static func testOne(_ outbound: String, url: String, timeoutMs: Int = 5000) -> Request {
        var q = CharacterSet.urlQueryAllowed
        q.remove(charactersIn: "&=?+")
        let u = url.addingPercentEncoding(withAllowedCharacters: q) ?? url
        return Request(method: "GET", path: "/proxies/\(enc(outbound))/delay?url=\(u)&timeout=\(timeoutMs)")
    }
    /// Delay-test every candidate of a urltest with its own URL.
    public static func test(_ urltest: String, timeoutMs: Int = 5000) -> Request {
        Request(method: "GET", path: "/group/\(enc(urltest))/delay?timeout=\(timeoutMs)")
    }
    /// The selector choices for a probe result.
    public static func apply(_ r: ProbeResult) -> [Request] { r.selections.map { select($0.group, $0.member) } }
}
