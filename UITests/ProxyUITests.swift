import XCTest

/// Walks every flow of the UI against a desktop sing-box running the real generated config (the simulator can't
/// run the packet tunnel): switch International both ways, pin a node, back to Auto, switch AI, run the Test.
/// Screenshots go to $SCREENSHOT_DIR (a host path; the workflow uploads them). Fails on a blank or stuck screen.
final class ProxyUITests: XCTestCase {
    var app: XCUIApplication!
    var shots = 0

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        for k in ["PROXY_MOCK_CLASH", "PROXY_MOCK_SECRET", "PROXY_MOCK_HTTP_PROXY"] { app.launchEnvironment[k] = env[k] }
        app.launch()
    }

    func shot(_ name: String) {
        shots += 1
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%02d-%@.png", shots, name)))
        }
    }

    func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func waitValue(_ id: String, _ value: String, timeout: TimeInterval = 15) {
        let e = el(id)
        let p = NSPredicate(format: "value == %@", value)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: p, evaluatedWith: e)], timeout: timeout), .completed,
                       "\(id) never became \(value)")
    }

    func waitLabel(_ id: String, _ label: String, timeout: TimeInterval = 15) {
        let p = NSPredicate(format: "label == %@", label)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: p, evaluatedWith: el(id))], timeout: timeout), .completed,
                       "\(id) never showed \(label)")
    }

    func scrollTo(_ e: XCUIElement) {
        var n = 0
        while !e.isHittable && n < 12 { app.swipeUp(); n += 1 }
    }

    func testEveryFlow() {
        let up = el("switch-咕噜HK").waitForExistence(timeout: 30)
        if !up {
            shot("never-loaded")
            print("UI tree when the switches never appeared:\n\(app.debugDescription)")
        }
        XCTAssertTrue(up, "the switches never appeared")
        waitValue("switch-咕噜HK", "active")
        shot("main")

        el("switch-良心云HK").tap()
        waitValue("switch-良心云HK", "active")
        shot("international-liangxin")

        let pin = el("pin-良心云HK")
        scrollTo(pin)
        pin.tap()
        waitLabel("mode-良心云HK", "Pinned")
        shot("liangxin-hk-pinned")
        let auto = el("auto-良心云HK")
        scrollTo(auto)
        auto.tap()
        waitLabel("mode-良心云HK", "Auto")

        app.swipeDown(); app.swipeDown()
        el("switch-咕噜HK").tap()
        waitValue("switch-咕噜HK", "active")

        let sg = el("switch-咕噜SG")
        scrollTo(sg)
        sg.tap()
        waitValue("switch-咕噜SG", "active")
        shot("ai-gulu")
        el("switch-良心云SG").tap()
        waitValue("switch-良心云SG", "active")

        app.swipeDown(); app.swipeDown(); app.swipeDown()
        el("test-button").tap()
        let line = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'AI exit'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 90), "the test never finished")
        XCTAssertFalse(line.label.contains("no answer"), line.label)
        let intl = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'International exit: HK'")).firstMatch
        XCTAssertTrue(intl.exists, "International did not exit in HK")
        XCTAssertTrue(line.label.contains("exit (claude.ai): SG"), "AI did not exit in SG: \(line.label)")
        shot("test-result")
        app.swipeUp()
        shot("test-result-nodes")
    }
}
