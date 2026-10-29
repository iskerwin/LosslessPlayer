import XCTest

final class GlassScreenshots: XCTestCase {
    func testCaptureGlassScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["library-home"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["mini-player"].waitForExistence(timeout: 10))
        save("library")

        let songs = app.buttons["歌曲"]
        XCTAssertTrue(songs.waitForExistence(timeout: 8))
        songs.tap()
        XCTAssertTrue(app.descendants(matching: .any)["songs-list"].waitForExistence(timeout: 8))
        save("songs")

        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()

        app.tabBars.buttons["歌单"].tap()
        let playlist = app.descendants(matching: .any)["playlist-深夜"]
        if !playlist.waitForExistence(timeout: 8) {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "深夜")).firstMatch.tap()
        } else {
            playlist.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["playlist-detail"].waitForExistence(timeout: 8))
        save("playlist")

        app.descendants(matching: .any)["mini-player"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["now-playing"].waitForExistence(timeout: 8))
        sleep(1)
        save("now-playing")
    }

    func testProgressHitAreaAndPanelSelection() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()
        let mini = app.descendants(matching: .any)["mini-player"]
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        mini.tap()
        XCTAssertTrue(app.descendants(matching: .any)["now-playing"].waitForExistence(timeout: 8))
        let progress = app.descendants(matching: .any)["playback-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        // Accessibility frames are screen-space floating-point conversions.
        XCTAssertGreaterThanOrEqual(progress.frame.height, 44 - 0.001)
        let previous = progress.value as? String
        // Drag above the visible line to exercise the enlarged touch area.
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.2))
            .press(forDuration: 0.1, thenDragTo: progress.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.2)))
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in (progress.value as? String) != previous }, object: progress
        )
        wait(for: [changed], timeout: 5)
        let queue = app.buttons["显示播放队列"]
        queue.tap()
        XCTAssertTrue(queue.isSelected)
        XCTAssertTrue(app.staticTexts["接下来"].exists)
        // Existence does not imply the outgoing artwork transition has finished.
        sleep(1)
        save("now-playing-queue")
        queue.tap()
        XCTAssertFalse(queue.isSelected)
        app.buttons["收起播放器"].tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 8))
    }

    func testPlayerPullDownThreshold() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()
        let mini = app.descendants(matching: .any)["mini-player"]
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        mini.tap()
        let player = app.descendants(matching: .any)["now-playing"]
        XCTAssertTrue(player.waitForExistence(timeout: 8))
        let handle = app.buttons["收起播放器"]
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 45)))
        XCTAssertTrue(player.exists, "Below-threshold drag must preserve the player")
        // Horizontal gestures must not dismiss the player either.
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 100, dy: 15)))
        XCTAssertTrue(player.exists)
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 160)))
        XCTAssertTrue(mini.waitForExistence(timeout: 8))
        XCTAssertFalse(player.exists)
    }

    /// Control case, split out so a failure summary names the broken half:
    /// if this fails, skip/load is broken in the UI context; if only the
    /// swipe case below fails, the gesture is. Button queries are scoped to
    /// the player — the mini player behind the cover has buttons with the
    /// same labels ("下一首", "暂停"), and an unscoped query can pick those.
    func testTransportButtonsChangeTrack() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()
        let mini = app.descendants(matching: .any)["mini-player"]
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        mini.tap()
        let player = app.descendants(matching: .any)["now-playing"]
        XCTAssertTrue(player.waitForExistence(timeout: 8))
        XCTAssertTrue(player.staticTexts["Apologize"].waitForExistence(timeout: 5))
        sleep(1)
        player.buttons["下一首"].tap()
        XCTAssertTrue(player.staticTexts["Stop and Stare"].waitForExistence(timeout: 8))
        player.buttons["上一首"].tap()
        XCTAssertTrue(player.staticTexts["Apologize"].waitForExistence(timeout: 8))
    }

    func testArtworkSwipeChangesTrack() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()
        let mini = app.descendants(matching: .any)["mini-player"]
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        mini.tap()
        let player = app.descendants(matching: .any)["now-playing"]
        XCTAssertTrue(player.waitForExistence(timeout: 8))
        XCTAssertTrue(player.staticTexts["Apologize"].waitForExistence(timeout: 5))
        // Let the zoom presentation settle before dragging.
        sleep(1)
        // Swipe left across the artwork (screen coordinates, independent of
        // any element's accessibility frame): next track, like Music.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.35))
            .press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.35)))
        XCTAssertTrue(player.staticTexts["Stop and Stare"].waitForExistence(timeout: 8))
        XCTAssertFalse(player.staticTexts["Apologize"].exists)
        // The swipe does not return until the transition is idle, and the
        // new song keeps playing during that wait. Past 3 seconds,
        // skip(backwards:) restarts this song, so park the playhead first.
        player.buttons["暂停"].tap()
        let progress = player.descendants(matching: .any)["playback-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: progress.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5)))
        // Swipe right: back to the previous track.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.35))
            .press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.35)))
        XCTAssertTrue(player.staticTexts["Apologize"].waitForExistence(timeout: 8))
        save("now-playing-swipe")
    }

    func testGridDetailReturnsToSameSlotTwice() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()
        let albums = app.buttons["专辑"]
        XCTAssertTrue(albums.waitForExistence(timeout: 20))
        albums.tap()
        let album = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "album-card-")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 8))
        checkRepeatedCardReturn(app, cell: album)
        app.tabBars.buttons["歌单"].tap()
        let playlist = app.buttons["playlist-深夜"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 8))
        checkRepeatedCardReturn(app, cell: playlist)
    }

    private func checkRepeatedCardReturn(_ app: XCUIApplication, cell: XCUIElement) {
        let slot = cell.frame
        for _ in 0..<2 {
            cell.tap()
            let back = app.buttons["detail-card-back"]
            XCTAssertTrue(back.waitForExistence(timeout: 8))
            let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: back)
            wait(for: [hittable], timeout: 8)
            XCTAssertTrue(app.tabBars.buttons["歌单"].isHittable)
            XCTAssertTrue(app.descendants(matching: .any)["mini-player"].exists)
            back.tap()
            let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in cell.isHittable }, object: nil)
            wait(for: [returned], timeout: 8)
            XCTAssertEqual(cell.frame.minX, slot.minX, accuracy: 0.5)
            XCTAssertEqual(cell.frame.minY, slot.minY, accuracy: 0.5)
            XCTAssertEqual(cell.frame.width, slot.width, accuracy: 0.5)
            XCTAssertEqual(cell.frame.height, slot.height, accuracy: 0.5)
            XCTAssertFalse(app.buttons["detail-card-back"].exists)
        }
    }

    func testAlbumGridAndPlaylistArtworkEntry() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()
        let albums = app.buttons["专辑"]
        XCTAssertTrue(albums.waitForExistence(timeout: 20))
        albums.tap()
        XCTAssertTrue(app.descendants(matching: .any)["album-grid"].waitForExistence(timeout: 8))
        save("albums")
        app.tabBars.buttons["歌单"].tap()
        let playlist = app.descendants(matching: .any)["playlist-深夜"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 8))
        playlist.tap()
        XCTAssertTrue(app.descendants(matching: .any)["playlist-detail"].waitForExistence(timeout: 8))
        app.buttons["更多"].firstMatch.tap()
        app.buttons["修改封面"].tap()
        XCTAssertTrue(app.buttons["从文件选择"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["恢复自动封面"].exists)
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
