import XCTest

final class PlayerTransitionPerformanceTests: XCTestCase {
    func testSettledPresentationIncludesNativeControlsAfterReopening() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()
        for _ in 0..<2 {
            let title = app.descendants(matching: .any)["mini-player"].staticTexts["Apologize"]
            XCTAssertTrue(title.waitForExistence(timeout: 20))
            title.tap()
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
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart]
        measure(metrics: [XCTHitchMetric(application: app), XCTCPUMetric(application: app), XCTClockMetric()],
                options: options) {
            // Harvesting happens after the measured closure returns. Keep
            // this process alive until then; terminate the previous iteration
            // here so every measured presentation still starts in a fresh app.
            app.terminate()
            app.launch()
            let title = app.descendants(matching: .any)["mini-player"].staticTexts["Apologize"]
            XCTAssertTrue(title.waitForExistence(timeout: 20))
            startMeasuring()
            title.tap()
            let player = app.descendants(matching: .any)["now-playing"]
            let settled = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND value == %@", "已展开"), object: player.buttons["收起播放器"])
            wait(for: [settled], timeout: 8)
            stopMeasuring()
        }
        app.terminate()
    }
}
