import XCTest

/// iPad only: the sidebar's browse sections, the mini player beside them, and
/// the iPhone-era reselect gestures. CI runs this class on an iPad simulator.
final class IPadSidebarTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPad sidebar")
        }
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testBrowseSectionsOpenTheirOwnPages() throws {
        let app = launch()
        let sidebar = try sidebarCell("资料库", in: app)
        XCTAssertTrue(sidebar.isSelected)
        save("ipad-sidebar-library")

        try sidebarCell("艺术家", in: app).tap()
        XCTAssertTrue(app.navigationBars["艺术家"].waitForExistence(timeout: 8))
        // The artist's list row, not the mini player's artist line (which opens the player).
        app.cells.containing(NSPredicate(format: "label == %@", "OneRepublic")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["OneRepublic"].waitForExistence(timeout: 8))
        save("ipad-sidebar-artist")

        try sidebarCell("专辑", in: app).tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "album-card-"))
            .firstMatch.waitForExistence(timeout: 8))

        try sidebarCell("歌曲", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["songs-list"].waitForExistence(timeout: 8)
                      || app.navigationBars["歌曲"].waitForExistence(timeout: 2))

        // Each section keeps its own stack: the artist page is still there.
        try sidebarCell("艺术家", in: app).tap()
        XCTAssertTrue(app.navigationBars["OneRepublic"].waitForExistence(timeout: 8))
    }

    func testMiniOpensPlayerBesideSidebar() throws {
        let app = launch()
        _ = try sidebarCell("资料库", in: app)
        let mini = app.windows.descendants(matching: .any).matching(identifier: "mini-player").firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        let sidebarFrame = try sidebarCell("资料库", in: app).frame
        XCTAssertGreaterThanOrEqual(mini.frame.minX, sidebarFrame.maxX, "Mini must sit beside the sidebar")
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: mini.frame.midX, dy: mini.frame.midY)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["now-playing"].waitForExistence(timeout: 8))
        save("ipad-player")
        // EXPERIMENT (exp/ipad-grabber-tap, not for merge): which taps close the player?
        let player = app.descendants(matching: .any)["now-playing"]
        func closed(_ step: String) -> Bool {
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: player)
            let ok = XCTWaiter().wait(for: [gone], timeout: 6) == .completed
            NSLog("PROBE step=%@ closed=%@ value=%@", step, ok ? "yes" : "no",
                  (app.buttons["收起播放器"].value as? String) ?? "-")
            return ok
        }
        let handle = app.buttons["收起播放器"]
        NSLog("PROBE handle frame=%@ hittable=%@", NSCoder.string(for: handle.frame), handle.isHittable ? "yes" : "no")
        handle.tap()
        if !closed("grabber-center") {
            save("probe-after-grabber")
            handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
            if !closed("grabber-low") {
                app.descendants(matching: .any)["now-playing-artwork"].tap()
                if !closed("artwork") {
                    handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                        .press(forDuration: 0.15)
                    _ = closed("grabber-press")
                }
            }
        }
        XCTAssertTrue(mini.waitForExistence(timeout: 8))
    }

    func testReselectStillWorksFromSidebar() throws {
        let app = launch()
        try sidebarCell("歌单", in: app).tap()
        let card = app.descendants(matching: .any)["playlist-深夜"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()
        XCTAssertTrue(app.descendants(matching: .any)["playlist-detail"].waitForExistence(timeout: 8))
        try sidebarCell("歌单", in: app).tap()
        XCTAssertTrue(card.waitForExistence(timeout: 8))

        try sidebarCell("搜索", in: app).tap()
        XCTAssertEqual(app.keyboards.count, 0)
        try sidebarCell("搜索", in: app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
    }

    /// Portrait falls back to a top tab bar: the browse sections stay out of it.
    func testPortraitTabBarHidesBrowseSection() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()
        let library = app.buttons.matching(NSPredicate(format: "label == %@", "资料库")).firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        save("ipad-portrait")
        // The system lists each top-bar tab twice at the same frame, so
        // compare the set of labels in the bar's row, not a count.
        let row = app.buttons.allElementsBoundByIndex.filter {
            abs($0.frame.midY - library.frame.midY) < 1
                && $0.identifier != "ToggleSideBar" && $0.label != "更多" && !$0.label.isEmpty
        }
        XCTAssertEqual(Set(row.map(\.label)), ["资料库", "歌单", "收藏", "搜索"])
    }

    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()
        return app
    }

    /// Sidebar rows are cells, matched by label; the first match is the sidebar's own row.
    private func sidebarCell(_ label: String, in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        let cell = app.cells.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "sidebar row \(label)", file: file, line: line)
        return cell
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_SCREENSHOT_DIR"]
            ?? "/tmp/lossless-screenshots"
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
    }
}
