import Foundation
import XCTest
@testable import ProxyCore

func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    return try Data(contentsOf: url)
}

final class ConfigBuilderTests: XCTestCase {
    func build(_ subs: [Plan.Source: Data], _ mode: InboundMode = .tun) throws -> (BuildResult, [String: Any]) {
        var o = BuildOptions(clashSecret: "s3cret"); o.inbound = mode
        let r = try ConfigBuilder.build(subscriptions: subs, options: o)
        return (r, try JSONSerialization.jsonObject(with: Data(r.json.utf8)) as! [String: Any])
    }
    func all() throws -> [Plan.Source: Data] {
        [.liangxin: try fixture("liangxin.json"), .gulu: try fixture("gulu.json"), .cn: try fixture("cn.json")]
    }
    func outbound(_ c: [String: Any], _ tag: String) -> [String: Any]? {
        (c["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == tag }
    }

    func testGroupsPickTheValidNodes() throws {
        let (r, _) = try build(all())
        XCTAssertEqual(r.groups[Plan.china], ["咕噜 🇨🇳回国 广州|倍率 x3", "回国 广州 Hysteria2", "回国 广州 VLESS-Reality"])
        // every non-mainland node; 咕噜云 x1 left out (x3 only, as on the router)
        XCTAssertEqual(r.groups[Plan.intl], ["良心云 🇭🇰香港高速01|BGP|CMCU", "良心云 🇭🇰香港高速02|BGP|CMCU",
                                             "良心云 🇸🇬新加坡专线01|BGP|流媒体", "良心云 🇯🇵日本高速01|CTCU|0.5x",
                                             "咕噜 🇭🇰香港01|倍率 x3", "咕噜 🇭🇰香港02|倍率 x3", "咕噜 🇸🇬新加坡01|倍率 x3",
                                             "咕噜 🇯🇵日本|倍率 x3", "咕噜 🇲🇴澳门|倍率 x3"])
        // AI: no HK, Macau or mainland
        XCTAssertEqual(r.groups[Plan.ai], ["良心云 🇸🇬新加坡专线01|BGP|流媒体", "良心云 🇯🇵日本高速01|CTCU|0.5x",
                                           "咕噜 🇸🇬新加坡01|倍率 x3", "咕噜 🇯🇵日本|倍率 x3"])
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
    }

    func testTaiwanWithAChineseFlagIsNotMainland() {
        XCTAssertEqual(ConfigBuilder.groups(of: "🇨🇳台湾专线01|BGP|流媒体", source: .liangxin), [Plan.intl, Plan.ai])
        XCTAssertEqual(ConfigBuilder.groups(of: "🇨🇳中国香港01", source: .liangxin), [Plan.intl])
        XCTAssertEqual(ConfigBuilder.groups(of: "🇨🇳回国 上海|x1", source: .gulu), [Plan.china])
        XCTAssertEqual(ConfigBuilder.groups(of: "广州 Hysteria2", source: .cn), [Plan.china])
    }

    func testEachGroupIsASelectorOfTheNodesUrltestAndDirectNeverRaced() throws {
        let (r, c) = try build(all())
        for g in Plan.groups {
            let sel = outbound(c, g.tag)!
            XCTAssertEqual(sel["type"] as? String, "selector")
            // the nodes' urltest, every node itself so the real check can pin one, and direct as a member of its own
            XCTAssertEqual(sel["outbounds"] as? [String], [g.nodesTest] + r.groups[g.tag]! + [g.direct])
            let check = outbound(c, g.checkSelector)!
            XCTAssertEqual(check["type"] as? String, "selector")
            XCTAssertEqual(check["outbounds"] as? [String], r.groups[g.tag]! + [g.direct])
            XCTAssertEqual(sel["default"] as? String, g.nodesTest)
            let nodes = outbound(c, g.nodesTest)!
            XCTAssertEqual(nodes["type"] as? String, "urltest")
            XCTAssertEqual(nodes["outbounds"] as? [String], r.groups[g.tag])
            XCTAssertEqual(nodes["url"] as? String, g.testURL)
            XCTAssertEqual(outbound(c, g.direct)?["type"] as? String, "direct")
        }
        // no urltest anywhere has direct as a member: a node can never out-race a working direct route
        for o in c["outbounds"] as! [[String: Any]] where o["type"] as? String == "urltest" {
            XCTAssertFalse((o["outbounds"] as! [String]).contains { $0.hasPrefix(Plan.directPrefix) }, "\(o["tag"]!)")
        }
        XCTAssertEqual(outbound(c, "China·nodes")?["url"] as? String, "http://connect.rom.miui.com/generate_204")
    }

    func testRulesAndDNS() throws {
        let (_, c) = try build(all())
        let route = c["route"] as! [String: Any]
        XCTAssertEqual(route["final"] as? String, Plan.intl)
        let rules = route["rules"] as! [[String: Any]]
        let ai = rules.firstIndex { ($0["rule_set"] as? [String]) == ["geosite-ai"] }!
        let cn = rules.firstIndex { ($0["rule_set"] as? [String]) == ["geosite-cn", "geoip-cn"] }!
        XCTAssertEqual(rules[ai]["outbound"] as? String, Plan.ai)
        XCTAssertEqual(rules[cn]["outbound"] as? String, Plan.china)
        XCTAssertLessThan(ai, cn, "AI must match before the China rule")
        let dns = c["dns"] as! [String: Any]
        let servers = dns["servers"] as! [[String: Any]]
        XCTAssertEqual(servers.first { $0["tag"] as? String == "cn" }?["detour"] as? String, Plan.china)
        XCTAssertEqual(servers.first { $0["tag"] as? String == "remote" }?["detour"] as? String, Plan.intl)
        XCTAssertEqual((route["default_domain_resolver"] as? [String: Any])?["server"] as? String, "local")
        XCTAssertNil(outbound(c, "良心云 🇭🇰香港高速01|BGP|CMCU")?["domain_resolver"])
        XCTAssertNil(outbound(c, "良心云 剩余流量：1.00 TB"))
        XCTAssertNil(outbound(c, "自动选择"))
        XCTAssertEqual((c["inbounds"] as! [[String: Any]])[0]["type"] as? String, "tun")
        let paths = (route["rule_set"] as! [[String: Any]]).map { $0["path"] as! String }
        XCTAssertEqual(paths, ["$RULES/geosite-cn.srs", "$RULES/geoip-cn.srs", "$RULES/geosite-category-ai-!cn.srs"])
    }

    func testGroupWithoutNodesGoesDirectOnly() throws {
        let (r, c) = try build([.liangxin: fixture("liangxin.json")])
        XCTAssertNil(r.groups[Plan.china])
        XCTAssertEqual(outbound(c, "China·nodes")?["outbounds"] as? [String], ["direct·China"])
        XCTAssertEqual(outbound(c, "China")?["default"] as? String, "China·nodes")
        XCTAssertFalse(r.warnings.isEmpty)
    }

    func testBrokenSubscriptionsThrowNoNodes() {
        XCTAssertThrowsError(try build([.liangxin: Data("<html>".utf8)]))
    }

    func testMixedInboundForDesktopTests() throws {
        let (_, c) = try build([.gulu: fixture("gulu.json")], .mixed(port: 17891))
        let inb = (c["inbounds"] as! [[String: Any]])[0]
        XCTAssertEqual(inb["type"] as? String, "mixed")
        XCTAssertEqual(inb["listen_port"] as? Int, 17891)
    }
}

final class NetworkProbeTests: XCTestCase {
    func testChinaVerdicts() {
        let sz = NetworkProbe.chinaVerdict("当前 IP：1.2.3.4  来自于：中国 广东 深圳  联通\n")
        XCTAssertEqual(sz, .init(valid: true, exit: "CN 广东"))
        XCTAssertFalse(NetworkProbe.chinaVerdict("当前 IP：1.2.3.4  来自于：中国 香港  hkbn").valid)
        XCTAssertFalse(NetworkProbe.chinaVerdict("当前 IP：1.2.3.4  来自于：英国 伦敦").valid)
        XCTAssertEqual(NetworkProbe.chinaVerdict(nil), .init(valid: false, exit: nil))
    }

    func testTraceVerdicts() {
        let trace = "fl=1\nip=1.2.3.4\nloc=HK\ntls=TLSv1.3\n"
        XCTAssertEqual(NetworkProbe.intlVerdict(trace), .init(valid: true, exit: "HK"))
        XCTAssertEqual(NetworkProbe.aiVerdict(trace), .init(valid: false, exit: "HK"))
        XCTAssertFalse(NetworkProbe.intlVerdict("loc=CN\n").valid)
        XCTAssertTrue(NetworkProbe.aiVerdict("loc=SG\n").valid)
        XCTAssertFalse(NetworkProbe.aiVerdict("loc=MO\n").valid)
        XCTAssertFalse(NetworkProbe.aiVerdict(nil).valid)
    }

    func testSelectionsFollowTheVerdicts() {
        let r = ProbeResult.mock("China=0,International=1,AI=0")
        // direct valid = the selector goes straight to direct (no urltest, so no race); invalid = the nodes' urltest
        XCTAssertEqual(r.selections.map(\.member), ["China·nodes", "direct·International", "AI·nodes"])
        XCTAssertEqual(ClashCall.apply(r)[1].path, "/proxies/International")
        XCTAssertEqual(ClashCall.apply(r)[1].body, "{\"name\":\"direct·International\"}")
        // an empty/garbled spec = nothing valid
        XCTAssertEqual(ProbeResult.mock("").selections.map(\.member), ["China·nodes", "International·nodes", "AI·nodes"])
    }
}

final class ProxyStateTests: XCTestCase {
    func testParsesTheRunningConfigsProxies() throws {
        let s = try ProxyState.parse(fixture("proxies.json"))
        XCTAssertEqual(s.groups.map(\.tag), [Plan.china, Plan.intl, Plan.ai])
        let intl = s.groups[1]
        XCTAssertTrue(intl.directAllowed)
        XCTAssertEqual(intl.candidates.first?.tag, "direct·International")
        XCTAssertEqual(intl.candidates.first?.name, "Direct")
        XCTAssertEqual(intl.current, "direct·International")
        XCTAssertEqual(intl.auto, "direct·International")
        XCTAssertEqual(intl.nodesPick, "良心云 🇭🇰香港高速01|BGP|CMCU")
        XCTAssertFalse(intl.pinned)
        let cn = s.groups[0]
        XCTAssertFalse(cn.directAllowed)
        XCTAssertEqual(cn.candidates.map(\.name), ["🇨🇳回国 广州|倍率 x3", "广州 Hysteria2", "广州 VLESS-Reality"])
    }

    func testClashCallPathsAreEncoded() {
        XCTAssertEqual(ClashCall.select("国际", "x").path, "/proxies/%E5%9B%BD%E9%99%85")
        XCTAssertTrue(ClashCall.test("AI·nodes").path.hasPrefix("/group/AI%C2%B7nodes/delay"))
        XCTAssertEqual(ClashCall.testOne("direct·AI", url: "http://www.gstatic.com/generate_204").path,
                       "/proxies/direct%C2%B7AI/delay?url=http://www.gstatic.com/generate_204&timeout=5000")
    }
}

final class HealthCheckTests: XCTestCase {
    func testCheckInboundsLeadToTheirCheckSelectors() throws {
        let subs: [Plan.Source: Data] = [.liangxin: try fixture("liangxin.json"), .gulu: try fixture("gulu.json"), .cn: try fixture("cn.json")]
        let json = try ConfigBuilder.build(subscriptions: subs, options: BuildOptions(clashSecret: "s")).json
        let c = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let ins = c["inbounds"] as! [[String: Any]]
        let rules = (c["route"] as! [String: Any])["rules"] as! [[String: Any]]
        for (i, g) in Plan.groups.enumerated() {
            let inb = ins.first { $0["tag"] as? String == g.checkInbound }!
            XCTAssertEqual(inb["type"] as? String, "mixed")
            XCTAssertEqual(inb["listen"] as? String, "127.0.0.1")
            XCTAssertEqual(inb["listen_port"] as? Int, 9181 + i)
            let ri = rules.firstIndex { ($0["inbound"] as? [String]) == [g.checkInbound] }!
            XCTAssertEqual(rules[ri]["outbound"] as? String, g.checkSelector)
            // before every routing rule that could send it elsewhere
            XCTAssertLessThan(ri, rules.firstIndex { $0["rule_set"] != nil }!)
        }
        XCTAssertEqual(HealthCheck.ports(config: json), [Plan.china: 9181, Plan.intl: 9182, Plan.ai: 9183])
    }

    func testParsesAPinnedSelector() throws {
        let f = FakeClash(auto: ["International": "b"], delays: ["a": 300, "b": 100, "c": 200])
        f.select("International", "c")
        let s = try ProxyState.parse(f.proxies(), directAllowed: ["International": false])
        let g = s.groups.first { $0.tag == Plan.intl }!
        XCTAssertTrue(g.pinned)
        XCTAssertEqual(g.current, "c")
        XCTAssertEqual(g.auto, "b")
        XCTAssertFalse(g.directAllowed)
    }

    func testPassingPickStaysAutomatic() async {
        let f = FakeClash(auto: ["International": "b"], delays: ["a": 300, "b": 100, "c": 200])
        let r = await f.checker(bad: []).run(directAllowed: [:])
        let e = r.entries[Plan.intl]!
        XCTAssertTrue(e.passed); XCTAssertFalse(e.pinned); XCTAssertEqual(e.candidate, "b")
        XCTAssertNil(f.selected["International"])   // the group's selector is never touched
    }

    func testFailingPickPinsTheFastestPassingCandidate() async {
        let f = FakeClash(auto: ["International": "b"], delays: ["a": 300, "b": 100, "c": 200])
        let r = await f.checker(bad: ["b"]).run(directAllowed: [:])
        let e = r.entries[Plan.intl]!
        XCTAssertTrue(e.passed); XCTAssertTrue(e.pinned)
        XCTAssertEqual(e.candidate, "c")            // c (200 ms) before a (300 ms)
        XCTAssertEqual(e.failed, ["b"])
        XCTAssertEqual(f.selected["International"], "c")
        XCTAssertEqual(f.loads.filter { $0 == "b" }.count, 2)   // the pick gets a second try before it counts as failed
    }

    func testUnpinsWhenThePickPassesAgain() async {
        let f = FakeClash(auto: ["International": "b"], delays: ["a": 300, "b": 100, "c": 200])
        f.select("International", "c")
        let r = await f.checker(bad: []).run(directAllowed: [:])
        XCTAssertFalse(r.entries[Plan.intl]!.pinned)
        XCTAssertEqual(f.selected["International"], "International·nodes")
    }

    func testDirectAvailableIsUsedEvenWhenANodeIsFaster() async throws {
        // node b answers in 10 ms, direct in 400 ms: direct still wins, and no node is even tried
        let f = FakeClash(auto: ["International": "b"], delays: ["a": 300, "b": 10, "c": 200, "direct·International": 400])
        let r = await f.checker(bad: []).run(directAllowed: ["International": true])
        let e = r.entries[Plan.intl]!
        XCTAssertTrue(e.passed); XCTAssertFalse(e.pinned)
        XCTAssertEqual(e.candidate, "direct·International")
        XCTAssertEqual(f.selected["International"], "direct·International")
        XCTAssertEqual(Set(f.loads.filter { ["a", "b", "c"].contains($0) }), [])
        let g = try ProxyState.parse(f.proxies(), directAllowed: ["International": true]).groups.first { $0.tag == Plan.intl }!
        XCTAssertEqual(g.current, "direct·International")
        XCTAssertFalse(g.pinned)
    }

    func testDirectUnavailableFallsBackToTheNodes() async throws {
        // direct is valid by the probe but fails the real check: the fastest node takes over
        let f = FakeClash(auto: ["International": "b"], delays: ["a": 300, "b": 10, "c": 200, "direct·International": 400])
        f.select("International", "direct·International")
        let r = await f.checker(bad: ["direct·International"]).run(directAllowed: ["International": true])
        let e = r.entries[Plan.intl]!
        XCTAssertTrue(e.passed); XCTAssertTrue(e.pinned)
        XCTAssertEqual(e.candidate, "b")
        XCTAssertEqual(e.failed, ["direct·International"])
        XCTAssertEqual(f.selected["International"], "International·nodes")
        XCTAssertEqual(f.loads.filter { $0 == "direct·International" }.count, 2)   // one lost request is not a failure
        let g = try ProxyState.parse(f.proxies(), directAllowed: ["International": true]).groups.first { $0.tag == Plan.intl }!
        XCTAssertEqual(g.current, "b")
        XCTAssertTrue(g.pinned)
    }

    func testDirectInvalidOnThisNetworkUsesTheNodesWithoutTryingDirect() async {
        let f = FakeClash(auto: ["International": "b"], delays: ["a": 300, "b": 100, "c": 200, "direct·International": 5])
        let r = await f.checker(bad: []).run(directAllowed: ["International": false])
        XCTAssertEqual(r.entries[Plan.intl]!.candidate, "b")
        XCTAssertFalse(f.loads.contains("direct·International"))
        XCTAssertNil(f.selected["International"])
    }

    func testBackToDirectOnceItPassesAgain() async {
        let f = FakeClash(auto: ["International": "b"], delays: ["a": 300, "b": 10, "c": 200])
        f.select("International", "International·nodes")    // fell back earlier
        let r = await f.checker(bad: []).run(directAllowed: ["International": true])
        XCTAssertFalse(r.entries[Plan.intl]!.pinned)
        XCTAssertEqual(r.entries[Plan.intl]!.candidate, "direct·International")
        XCTAssertEqual(f.selected["International"], "direct·International")
    }

    func testNothingPassesLeavesTheUrltest() async {
        let f = FakeClash(auto: ["International": "b"], delays: ["a": 300, "b": 100, "c": 200])
        f.select("International", "c")
        let r = await f.checker(bad: ["a", "b", "c"]).run(directAllowed: [:])
        let e = r.entries[Plan.intl]!
        XCTAssertFalse(e.passed); XCTAssertFalse(e.pinned)
        XCTAssertEqual(Set(e.failed), ["a", "b", "c"])
        XCTAssertEqual(f.selected["International"], "International·nodes")
    }
}

/// A Clash API with one International group of nodes a, b, c (no China/AI candidates beyond direct), whose
/// selectors remember PUTs; `load` passes unless the check selector points at a "bad" candidate.
final class FakeClash: @unchecked Sendable {
    let lock = NSLock()
    var selected: [String: String] = [:]
    var loads: [String] = []
    let auto: [String: String]
    let delays: [String: Int]
    init(auto: [String: String], delays: [String: Int]) { self.auto = auto; self.delays = delays }

    func select(_ g: String, _ m: String) { lock.lock(); selected[g] = m; lock.unlock() }

    func proxies() -> Data {
        lock.lock(); defer { lock.unlock() }
        var p: [String: Any] = [:]
        for g in Plan.groups {
            let nodes = g.tag == Plan.intl ? ["a", "b", "c"] : [g.direct]
            let members = [g.nodesTest] + nodes + (nodes.contains(g.direct) ? [] : [g.direct])
            p[g.tag] = ["type": "Selector", "now": selected[g.tag] ?? g.nodesTest, "all": members]
            p[g.nodesTest] = ["type": "URLTest", "now": auto[g.tag] ?? nodes[0], "all": nodes]
            p[g.checkSelector] = ["type": "Selector", "now": selected[g.checkSelector] ?? g.direct, "all": nodes + [g.direct]]
        }
        for (t, d) in delays { p[t] = ["type": "VLESS", "history": [["delay": d]]] }
        return try! JSONSerialization.data(withJSONObject: ["proxies": p])
    }

    func checker(bad: Set<String>) -> HealthCheck {
        HealthCheck(call: { r in
            if r.method == "GET" { return .init(status: 200, body: String(decoding: self.proxies(), as: UTF8.self)) }
            let name = (try! JSONSerialization.jsonObject(with: Data(r.body!.utf8)) as! [String: String])["name"]!
            let group = r.path.replacingOccurrences(of: "/proxies/", with: "").removingPercentEncoding!
            self.select(group, name)
            return .init(status: 204, body: "")
        }, load: { group, _ in
            let c = self.lock.withLock { self.selected[Plan.group(group)!.checkSelector] ?? "" }
            self.lock.withLock { self.loads.append(c) }
            return .init(passed: !bad.contains(c), exit: "US", ms: 100)
        }, ports: [Plan.china: 1, Plan.intl: 2, Plan.ai: 3])
    }
}
