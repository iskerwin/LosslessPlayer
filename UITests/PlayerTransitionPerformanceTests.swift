import XCTest

final class PlayerTransitionPerformanceTests: XCTestCase {
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
            app.launch()
            let title = app.descendants(matching: .any)["mini-player"].staticTexts["Apologize"]
            XCTAssertTrue(title.waitForExistence(timeout: 20))
            startMeasuring()
            title.tap()
            let player = app.descendants(matching: .any)["now-playing"]
            let settled = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND value == %@", "已展开"), object: player)
            wait(for: [settled], timeout: 8)
            stopMeasuring()
            app.terminate()
        }
    }
}
