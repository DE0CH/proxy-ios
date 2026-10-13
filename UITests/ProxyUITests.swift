import XCTest

/// Walks every flow of the UI against a desktop sing-box running the real generated config (the simulator can't
/// run the packet tunnel): the network probe from the runner and its selector choices, a re-check, the Test (every
/// group's exit), then a relaunch with a mocked China network (PROXY_MOCK_PROBE) flipping every group.
/// Screenshots go to $SCREENSHOT_DIR (a host path; the workflow uploads them). Fails on a blank or stuck screen.
final class ProxyUITests: XCTestCase {
    var app: XCUIApplication!
    var shots = 0
    let env = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
        launch(probe: nil)
    }

    func launch(probe: String?) {
        app?.terminate()
        app = XCUIApplication()
        for k in ["PROXY_MOCK_CLASH", "PROXY_MOCK_SECRET", "PROXY_MOCK_HTTP_PROXY"] { app.launchEnvironment[k] = env[k] }
        if let probe { app.launchEnvironment["PROXY_MOCK_PROBE"] = probe }
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
        var n = 0
        while !e.exists && n < 8 { app.swipeUp(); n += 1 }   // List rows below the fold don't exist yet
        let p = NSPredicate(format: "value == %@", value)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: p, evaluatedWith: e)], timeout: timeout), .completed,
                       "\(id) never became \(value)")
    }

    func waitLabel(_ id: String, _ label: String, timeout: TimeInterval = 15) {
        let p = NSPredicate(format: "label == %@", label)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: p, evaluatedWith: el(id))], timeout: timeout), .completed,
                       "\(id) never showed \(label)")
    }

    func top() { for _ in 0..<5 { app.swipeDown() } }

    func scrollTo(_ e: XCUIElement) {
        var n = 0
        while !e.isHittable && n < 12 { app.swipeUp(); n += 1 }
    }

    func testEveryFlow() {
        let up = el("test-button").waitForExistence(timeout: 30)
        if !up {
            shot("never-loaded")
            print("UI tree when the groups never appeared:\n\(app.debugDescription)")
        }
        XCTAssertTrue(up, "the groups never appeared")
        // the runner is outside China: direct is invalid for China, valid for International and AI
        waitValue("probe-China", "invalid", timeout: 30)
        waitValue("probe-International", "valid")
        waitValue("direct-China", "not allowed")
        waitValue("direct-International", "allowed")
        waitValue("direct-AI", "allowed")
        top()
        shot("main")

        let recheck = el("recheck-button")
        scrollTo(recheck)
        recheck.tap()
        waitValue("direct-International", "allowed")
        shot("rechecked")

        top()
        el("test-button").tap()
        let line = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'AI exit'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 120), "the test never finished")
        XCTAssertFalse(line.label.contains("no answer"), line.label)
        XCTAssertFalse(line.label.contains("claude.ai): CN") || line.label.contains("claude.ai): HK"), "AI exited in CN/HK: \(line.label)")
        let intl = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'International exit: '")).firstMatch
        XCTAssertTrue(intl.exists)
        XCTAssertFalse(intl.label.hasPrefix("International exit: CN") || intl.label.contains("no answer"), intl.label)
        if env["PROXY_EXPECT_CN"] == "1" {
            let cn = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'China exit: CN'")).firstMatch
            XCTAssertTrue(cn.exists, "China did not exit in mainland China")
        }
        shot("test-result")
        app.swipeUp()
        shot("test-result-groups")
        app.swipeUp()
        shot("groups-ai")

        // a mainland network with no split: direct is valid for China only
        launch(probe: "China=1,International=0,AI=0")
        XCTAssertTrue(el("test-button").waitForExistence(timeout: 30))
        waitValue("direct-China", "allowed")
        waitValue("direct-International", "not allowed")
        waitValue("direct-AI", "not allowed")
        top()
        shot("mainland-network")
    }
}
