import Foundation
import XCTest
@testable import ProxyCore

final class ConfigBuilderTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return try Data(contentsOf: url)
    }
    func build(_ subs: [Plan.Airport: Data], _ mode: InboundMode = .tun) throws -> (BuildResult, [String: Any]) {
        var o = BuildOptions(clashSecret: "s3cret"); o.inbound = mode
        let r = try ConfigBuilder.build(subscriptions: subs, options: o)
        return (r, try JSONSerialization.jsonObject(with: Data(r.json.utf8)) as! [String: Any])
    }
    func outbound(_ c: [String: Any], _ tag: String) -> [String: Any]? {
        (c["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == tag }
    }

    func testRegionsPickTheRightNodes() throws {
        let (r, _) = try build([.liangxin: fixture("liangxin.json"), .gulu: fixture("gulu.json")])
        XCTAssertEqual(r.regions[Plan.guluHK], ["咕噜 🇭🇰香港01|倍率 x3", "咕噜 🇭🇰香港02|倍率 x3"])   // x1 and JP left out
        XCTAssertEqual(r.regions[Plan.guluSG], ["咕噜 🇸🇬新加坡01|倍率 x3"])
        XCTAssertEqual(r.regions[Plan.liangxinHK], ["良心云 🇭🇰香港高速01|BGP|CMCU", "良心云 🇭🇰香港高速02|BGP|CMCU"])
        XCTAssertEqual(r.regions[Plan.liangxinSG], ["良心云 🇸🇬新加坡专线01|BGP|流媒体"])
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
    }

    func testSwitchesRegionGroupsAndRules() throws {
        let (_, c) = try build([.liangxin: fixture("liangxin.json"), .gulu: fixture("gulu.json")])
        XCTAssertEqual(outbound(c, "国际")?["outbounds"] as? [String], ["咕噜HK", "良心云HK"])
        XCTAssertEqual(outbound(c, "国际")?["default"] as? String, "咕噜HK")
        XCTAssertEqual(outbound(c, "AI")?["outbounds"] as? [String], ["良心云SG", "咕噜SG"])
        XCTAssertEqual(outbound(c, "AI")?["default"] as? String, "良心云SG")
        let hk = outbound(c, "咕噜HK")!
        XCTAssertEqual(hk["type"] as? String, "selector")
        XCTAssertEqual((hk["outbounds"] as! [String]).first, "咕噜HK·Auto")
        XCTAssertEqual(hk["default"] as? String, "咕噜HK·Auto")
        let auto = outbound(c, "咕噜HK·Auto")!
        XCTAssertEqual(auto["type"] as? String, "urltest")
        XCTAssertEqual(auto["url"] as? String, "http://www.gstatic.com/generate_204")
        let route = c["route"] as! [String: Any]
        XCTAssertEqual(route["final"] as? String, "国际")
        let rules = route["rules"] as! [[String: Any]]
        let ai = rules.firstIndex { ($0["rule_set"] as? [String]) == ["geosite-ai"] }!
        let cn = rules.firstIndex { ($0["rule_set"] as? [String]) == ["geosite-cn", "geoip-cn"] }!
        XCTAssertEqual(rules[ai]["outbound"] as? String, "AI")
        XCTAssertEqual(rules[cn]["outbound"] as? String, "direct")
        XCTAssertLessThan(ai, cn, "AI must match before the China rule")
        XCTAssertNil(outbound(c, "良心云 🇭🇰香港高速01|BGP|CMCU")?["domain_resolver"])
        XCTAssertNil(outbound(c, "良心云 剩余流量：18.98 TB"))
        XCTAssertNil(outbound(c, "自动选择"))
        XCTAssertEqual((c["inbounds"] as! [[String: Any]])[0]["type"] as? String, "tun")
        let paths = (route["rule_set"] as! [[String: Any]]).map { $0["path"] as! String }
        XCTAssertEqual(paths, ["$RULES/geosite-cn.srs", "$RULES/geoip-cn.srs", "$RULES/geosite-category-ai-!cn.srs"])
    }

    func testMissingAirportLeavesItsRegionsOut() throws {
        let (r, c) = try build([.liangxin: fixture("liangxin.json")])
        XCTAssertNil(r.regions[Plan.guluHK])
        XCTAssertEqual(outbound(c, "国际")?["outbounds"] as? [String], ["良心云HK"])
        XCTAssertEqual(outbound(c, "AI")?["outbounds"] as? [String], ["良心云SG"])
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

final class ProxyStateTests: XCTestCase {
    func testParsesTheRunningConfigsProxies() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/proxies.json")
        let s = try ProxyState.parse(Data(contentsOf: url))
        XCTAssertEqual(s.switches.map(\.tag), ["国际", "AI"])
        let intl = s.switches[0]
        XCTAssertEqual(intl.selected, "咕噜HK")
        XCTAssertEqual(intl.regions.map(\.group), ["咕噜HK", "良心云HK"])
        let lx = intl.regions[1]
        XCTAssertTrue(lx.auto)
        XCTAssertEqual(lx.nodes.count, 5)
        XCTAssertFalse(lx.nodes.contains { $0.tag.hasSuffix("·Auto") })
        XCTAssertNotNil(lx.current)
        XCTAssertEqual(lx.nodes[0].name, "🇭🇰香港高速01|BGP|CMCU")
        XCTAssertEqual(s.switches[1].selected, "良心云SG")
    }

    func testClashCallPathsAreEncoded() {
        XCTAssertEqual(ClashCall.select("国际", "咕噜HK").path, "/proxies/%E5%9B%BD%E9%99%85")
        XCTAssertEqual(ClashCall.select("国际", "咕噜HK").body, "{\"name\":\"咕噜HK\"}")
        XCTAssertTrue(ClashCall.testRegion(Plan.guluHK).path.hasPrefix("/group/%E5%92%95%E5%99%9CHK%C2%B7Auto/delay"))
    }
}
