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
        XCTAssertTrue(player.waitForExistence(timeout: 8))
        XCTAssertTrue(player.staticTexts["Apologize"].waitForExistence(timeout: 5))
        // Let the zoom presentation settle before interacting.
        sleep(1)
        // Control group: the transport buttons must change the track in this
        // same UI context. If this fails, playback — not the gesture — is
        // broken; if it passes, only the swipe assertions below can fail.
        app.buttons["下一首"].tap()
        XCTAssertTrue(player.staticTexts["Stop and Stare"].waitForExistence(timeout: 8))
        app.buttons["上一首"].tap()
        XCTAssertTrue(player.staticTexts["Apologize"].waitForExistence(timeout: 8))
        // Swipe left across the artwork (screen coordinates, independent of
        // any element's accessibility frame): next track, like Music.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.35))
            .press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.35)))
        XCTAssertTrue(player.staticTexts["Stop and Stare"].waitForExistence(timeout: 8))
        XCTAssertFalse(player.staticTexts["Apologize"].exists)
        // Pause so the position stays under the 3-second restart threshold
        // of skip(backwards:) no matter how slow the simulator runs.
        app.buttons["暂停"].tap()
        // Swipe right: back to the previous track.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.35))
            .press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.35)))
        XCTAssertTrue(player.staticTexts["Apologize"].waitForExistence(timeout: 8))
        save("now-playing-swipe")
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
