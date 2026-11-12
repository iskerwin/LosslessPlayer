import XCTest

final class PlayerTransitionPerformanceTests: XCTestCase {
    func testSettledPresentationIncludesNativeControlsAfterReopening() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()
        for _ in 0..<2 {
            let player = presentSettledPlayer(in: app)
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
        // started. Launching again inside the block replaces that process.
        // The simulator still has an empty hitch archive after the animation
        // finishes (run 43255604064: four opens settled, one process), and
        // harvest asserts `_data`. Record hitches on device only.
        app.launch()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart]
        let iteration = {
            let frame = self.stableMiniFrame(in: app)
            let player = app.descendants(matching: .any)["now-playing"]
            self.startMeasuring()
            let openedAt = self.tapOpening(frame, in: app, player: player)
            self.waitUntilSettled(player, openedAt: openedAt)
            self.stopMeasuring()
            // A full close unmounts the card, so the next open is cold again.
            // The process stays up until measure returns and harvest finishes.
            player.buttons["收起播放器"].tap()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: player)
            self.wait(for: [closed], timeout: 8)
        }
        #if targetEnvironment(simulator)
        measure(metrics: [XCTCPUMetric(application: app), XCTClockMetric()], options: options, block: iteration)
        #else
        measure(metrics: [XCTHitchMetric(application: app), XCTCPUMetric(application: app), XCTClockMetric()],
                options: options, block: iteration)
        #endif
        app.terminate()
    }

    /// The accessory reports a title before its screen frame is usable, and
    /// that title's accessibility activation point misses the open control.
    /// Screenshot coverage taps the stable frame's center for the same reason.
    /// That center tap is sometimes dropped outright (run 43248405785: the
    /// library never changed). A dropped tap leaves now-playing absent and is
    /// repeated once. It does not spend the 8s settle budget; that budget
    /// still starts at the tap the wait follows.
    private func presentSettledPlayer(in app: XCUIApplication, file: StaticString = #filePath,
                                      line: UInt = #line) -> XCUIElement {
        let player = app.descendants(matching: .any)["now-playing"]
        let openedAt = tapOpening(stableMiniFrame(in: app, file: file, line: line), in: app, player: player,
                                  file: file, line: line)
        waitUntilSettled(player, openedAt: openedAt)
        return player
    }

    private func tapOpening(_ frame: CGRect, in app: XCUIApplication, player: XCUIElement,
                            file: StaticString = #filePath, line: UInt = #line) -> Date {
        let first = sendTap(frame, in: app)
        if player.waitForExistence(timeout: 2) { return first }
        return sendTap(stableMiniFrame(in: app, file: file, line: line), in: app)
    }

    private func sendTap(_ frame: CGRect, in app: XCUIApplication) -> Date {
        let openedAt = Date()
        tap(frame, in: app)
        return openedAt
    }

    private func waitUntilSettled(_ player: XCUIElement, openedAt: Date) {
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == %@", "已展开"),
            object: player.buttons["收起播放器"])
        let remaining = 8 - Date().timeIntervalSince(openedAt)
        wait(for: [settled], timeout: max(0, remaining))
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
