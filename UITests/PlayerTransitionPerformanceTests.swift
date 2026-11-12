import XCTest

final class PlayerTransitionPerformanceTests: XCTestCase {
    func testSettledPresentationIncludesNativeControlsAfterReopening() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()
        for _ in 0..<2 {
            tapMini(in: app)
            let player = app.descendants(matching: .any)["now-playing"]
            let settled = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND value == %@", "已展开"), object: player.buttons["收起播放器"])
            wait(for: [settled], timeout: 8)
            XCTAssertTrue(player.descendants(matching: .any)["player-route-picker"].waitForExistence(timeout: 5))
            player.buttons["收起播放器"].tap()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: player)
            wait(for: [closed], timeout: 8)
        }
    }

    func testColdPlayerPresentationHitches() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Hitch metrics require iOS 26") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        // Hitch harvest reads the process that was running when measurement
        // started. Launching again inside the block replaces that process and
        // leaves the signpost buffer empty.
        app.launch()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart]
        measure(metrics: [XCTHitchMetric(application: app), XCTCPUMetric(application: app), XCTClockMetric()],
                options: options) {
            let frame = stableMiniFrame(in: app)
            startMeasuring()
            tap(frame, in: app)
            let player = app.descendants(matching: .any)["now-playing"]
            let settled = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND value == %@", "已展开"), object: player.buttons["收起播放器"])
            wait(for: [settled], timeout: 8)
            stopMeasuring()
            // A full close unmounts the card, so the next open is cold again.
            // The process stays up until measure returns and harvest finishes.
            player.buttons["收起播放器"].tap()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: player)
            wait(for: [closed], timeout: 8)
        }
        app.terminate()
    }

    /// The accessory reports a title before its screen frame is usable, and
    /// that title's accessibility activation point misses the open control.
    /// Screenshot coverage taps the stable frame's center for the same reason.
    private func tapMini(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        tap(stableMiniFrame(in: app, file: file, line: line), in: app)
    }

    private func tap(_ frame: CGRect, in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + frame.width * 0.5, dy: frame.minY + frame.height * 0.5))
            .tap()
    }

    private func stableMiniFrame(in app: XCUIApplication, file: StaticString = #filePath,
                                 line: UInt = #line) -> CGRect {
        let mini = app.windows.descendants(matching: .any)
            .matching(identifier: "mini-player").firstMatch
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while ProcessInfo.processInfo.systemUptime < deadline {
            if mini.exists {
                let first = mini.frame
                if isValidMiniFrame(first) {
                    Thread.sleep(forTimeInterval: 0.25)
                    if mini.frame == first { return first }
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("Mini accessory must have a finite, nonempty, stable frame", file: file, line: line)
        return .zero
    }

    private func isValidMiniFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }
}
