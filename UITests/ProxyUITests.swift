import XCTest

/// Walks every flow of the UI against a desktop sing-box running the real generated config (the simulator can't
/// run the packet tunnel): the network probe from the runner and its selector choices, a re-check, the Test (every
/// group's exit), the real check of every group's candidate in use, then a relaunch with a mocked China network
/// (PROXY_MOCK_PROBE) flipping every group. It starts at the unlock screen (Keychain cleared): a wrong password must
/// be refused, the real one (PROXY_UNLOCK_PASSWORD) opens the sealed subscriptions, and the relaunch must not ask
/// again. The same file runs on the iPhone simulator and on the Mac.
/// Screenshots go to $SCREENSHOT_DIR (a host path; the workflow uploads them). Fails on a blank or stuck screen.
final class ProxyUITests: XCTestCase {
    var app: XCUIApplication!
    var shots = 0
    let env = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
        launch(probe: nil, resetUnlock: true)
    }

    func launch(probe: String?, resetUnlock: Bool = false) {
        app?.terminate()
        app = XCUIApplication()
        for k in ["PROXY_MOCK_CLASH", "PROXY_MOCK_SECRET", "PROXY_MOCK_HTTP_PROXY", "PROXY_MOCK_CHECK_PORT_BASE"] {
            app.launchEnvironment[k] = env[k]
        }
        if let probe { app.launchEnvironment["PROXY_MOCK_PROBE"] = probe }
        if resetUnlock { app.launchEnvironment["PROXY_RESET_UNLOCK"] = "1" }
        app.launch()
    }

    func press(_ e: XCUIElement) {
        #if os(iOS)
        e.tap()
        #else
        e.click()
        #endif
    }

    // scrolling: swipes on the phone, scroll-wheel deltas on the Mac
    func scrollDown() {
        #if os(iOS)
        app.swipeUp()
        #else
        app.windows.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
        #endif
    }
    func scrollUp() {
        #if os(iOS)
        app.swipeDown()
        #else
        app.windows.firstMatch.scroll(byDeltaX: 0, deltaY: 4000)
        #endif
    }

    func unlock() {
        let pw = el("unlock-password")
        XCTAssertTrue(pw.waitForExistence(timeout: 20), "no unlock screen on a fresh install")
        press(pw); pw.typeText("not-the-password")
        press(el("unlock-button"))
        XCTAssertTrue(el("unlock-error").waitForExistence(timeout: 10), "a wrong password was not refused")
        shot("unlock-wrong")
        let real = env["PROXY_UNLOCK_PASSWORD"] ?? ""
        XCTAssertFalse(real.isEmpty, "PROXY_UNLOCK_PASSWORD is not set for the test")
        press(pw)
        pw.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        pw.typeText(real)
        press(el("unlock-button"))
    }

    func waitValue(_ id: String, oneOf values: [String], timeout: TimeInterval = 60) {
        let e = el(id)
        var n = 0
        while !e.exists && n < 8 { scrollDown(); n += 1 }
        let p = NSPredicate(format: "value IN %@", values)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: p, evaluatedWith: e)], timeout: timeout), .completed,
                       "\(id) never became one of \(values) (is \(e.value ?? "nil"))")
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

    func text(_ e: XCUIElement) -> String { e.label.isEmpty ? (e.value as? String ?? "") : e.label }

    func waitValue(_ id: String, _ value: String, timeout: TimeInterval = 15) {
        let e = el(id)
        var n = 0
        while !e.exists && n < 8 { scrollDown(); n += 1 }   // List rows below the fold don't exist yet
        let p = NSPredicate(format: "value == %@", value)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: p, evaluatedWith: e)], timeout: timeout), .completed,
                       "\(id) never became \(value)")
    }

    func waitLabel(_ id: String, _ label: String, timeout: TimeInterval = 15) {
        let p = NSPredicate(format: "label == %@", label)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: p, evaluatedWith: el(id))], timeout: timeout), .completed,
                       "\(id) never showed \(label)")
    }

    func top() { for _ in 0..<5 { scrollUp() } }

    func scrollTo(_ e: XCUIElement) {
        var n = 0
        while !e.isHittable && n < 12 { scrollDown(); n += 1 }
    }

    func testEveryFlow() {
        unlock()
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
        press(recheck)
        waitValue("direct-International", "allowed")
        shot("rechecked")

        top()
        press(el("test-button"))
        // test-line-1…3: China / International / AI exit (a Text's content is its label on iOS, its value on the Mac)
        let line = el("test-line-3")
        XCTAssertTrue(line.waitForExistence(timeout: 120), "the test never finished")
        let ai = text(line), intl = text(el("test-line-2")), cn = text(el("test-line-1"))
        XCTAssertTrue(ai.hasPrefix("AI exit"), ai)
        XCTAssertFalse(ai.contains("no answer"), ai)
        XCTAssertFalse(ai.contains("claude.ai): CN") || ai.contains("claude.ai): HK"), "AI exited in CN/HK: \(ai)")
        XCTAssertFalse(intl.hasPrefix("International exit: CN") || intl.contains("no answer"), intl)
        if env["PROXY_EXPECT_CN"] == "1" { XCTAssertTrue(cn.hasPrefix("China exit: CN"), "China did not exit in mainland China") }
        // the real check: every group's candidate in use loads a real page (or the group switched to one that does)
        waitValue("health-International", oneOf: ["passed", "pinned"])
        waitValue("health-AI", oneOf: ["passed", "pinned"])
        if env["PROXY_EXPECT_CN"] == "1" { waitValue("health-China", oneOf: ["passed", "pinned"]) }
        top()
        shot("test-result")
        scrollDown()
        shot("test-result-groups")
        scrollDown()
        shot("groups-ai")

        // a mainland network with no split: direct is valid for China only; the password is remembered
        launch(probe: "China=1,International=0,AI=0")
        XCTAssertTrue(el("test-button").waitForExistence(timeout: 30), "the relaunch did not skip the unlock screen")
        XCTAssertFalse(el("unlock-password").exists)
        waitValue("direct-China", "allowed")
        waitValue("direct-International", "not allowed")
        waitValue("direct-AI", "not allowed")
        top()
        shot("mainland-network")
    }
}
