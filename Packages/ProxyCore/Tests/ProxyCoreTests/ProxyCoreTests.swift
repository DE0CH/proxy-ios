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

    func testEachGroupIsASelectorOfNodesAndNodesPlusDirect() throws {
        let (r, c) = try build(all())
        for g in Plan.groups {
            let sel = outbound(c, g.tag)!
            XCTAssertEqual(sel["type"] as? String, "selector")
            XCTAssertEqual(sel["outbounds"] as? [String], [g.nodesTest, g.allTest])
            XCTAssertEqual(sel["default"] as? String, g.nodesTest)
            let nodes = outbound(c, g.nodesTest)!, both = outbound(c, g.allTest)!
            XCTAssertEqual(nodes["type"] as? String, "urltest")
            XCTAssertEqual(nodes["outbounds"] as? [String], r.groups[g.tag])
            XCTAssertEqual(both["outbounds"] as? [String], r.groups[g.tag]! + [g.direct])
            XCTAssertEqual(both["url"] as? String, g.testURL)
            XCTAssertEqual(outbound(c, g.direct)?["type"] as? String, "direct")
        }
        XCTAssertEqual(outbound(c, "China·all")?["url"] as? String, "http://connect.rom.miui.com/generate_204")
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

    func testGroupWithoutNodesRacesDirectAlone() throws {
        let (r, c) = try build([.liangxin: fixture("liangxin.json")])
        XCTAssertNil(r.groups[Plan.china])
        XCTAssertEqual(outbound(c, "China·nodes")?["outbounds"] as? [String], ["direct·China"])
        XCTAssertEqual(outbound(c, "China")?["default"] as? String, "China·all")
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
        XCTAssertEqual(r.selections.map(\.member), ["China·nodes", "International·all", "AI·nodes"])
        XCTAssertEqual(ClashCall.apply(r)[1].path, "/proxies/International")
        XCTAssertEqual(ClashCall.apply(r)[1].body, "{\"name\":\"International·all\"}")
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
        XCTAssertTrue(intl.candidates.contains { $0.isDirect && $0.name == "Direct" })
        XCTAssertNotNil(intl.current)
        let cn = s.groups[0]
        XCTAssertFalse(cn.directAllowed)
        XCTAssertEqual(cn.candidates.map(\.name), ["🇨🇳回国 广州|倍率 x3", "广州 Hysteria2", "广州 VLESS-Reality"])
    }

    func testClashCallPathsAreEncoded() {
        XCTAssertEqual(ClashCall.select("国际", "x").path, "/proxies/%E5%9B%BD%E9%99%85")
        XCTAssertTrue(ClashCall.test("AI·all").path.hasPrefix("/group/AI%C2%B7all/delay"))
    }
}
