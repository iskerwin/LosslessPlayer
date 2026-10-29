import XCTest
import UIKit

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
        app.descendants(matching: .any)["songs-list"].swipeUp()
        save("songs-scrolled-glass")

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
        app.descendants(matching: .any)["playlist-detail"].swipeUp()
        save("playlist-scrolled-continuity")
        try assertCollectionBackground(app.descendants(matching: .any)["playlist-detail"])

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
        let shortcutReachedQueue = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"), object: queue)
        let didReachQueue = XCTWaiter.wait(for: [shortcutReachedQueue], timeout: 5) == .completed
        save("now-playing-queue-shortcut")
        if !didReachQueue { print(app.debugDescription) }
        XCTAssertTrue(didReachQueue, "Queue button must show state B")
        XCTAssertTrue(app.staticTexts["接下来"].exists)
        // Preserve a settled queue screenshot as well as the shortcut diagnostic.
        sleep(1)
        save("now-playing-queue")
        queue.tap()
        XCTAssertFalse(queue.isSelected)
        let artwork = app.descendants(matching: .any)["now-playing-artwork"]
        XCTAssertTrue(artwork.exists)
        XCTAssertFalse(app.scrollViews["now-playing-queue-scroll"].exists)
        // Swiping the large artwork must never reveal a hidden queue.
        artwork.swipeUp()
        XCTAssertFalse(queue.isSelected)
        XCTAssertFalse(app.staticTexts["接下来"].exists)
        let player = app.descendants(matching: .any)["now-playing"]
        XCTAssertTrue(player.exists)
        XCTAssertTrue(player.buttons["上一首"].isHittable)
        XCTAssertTrue(player.buttons["下一首"].isHittable)
        XCTAssertTrue(player.descendants(matching: .any)["playback-progress"].isHittable)
        // A sub-threshold downward drag also stays in A, without a queue.
        let start = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 45)))
        XCTAssertFalse(queue.isSelected)
        XCTAssertTrue(player.exists)
        save("now-playing-no-swipe-queue")
        // The lyrics shortcut must still reach the queue through the same button.
        player.buttons["显示歌词"].tap()
        XCTAssertTrue(player.exists)
        queue.tap()
        XCTAssertTrue(queue.isSelected)
        XCTAssertTrue(app.staticTexts["接下来"].exists)
        let queueScroll = app.scrollViews["now-playing-queue-scroll"]
        XCTAssertTrue(queueScroll.exists)
        queueScroll.swipeUp()
        XCTAssertTrue(queue.isSelected)
        XCTAssertTrue(player.exists)
        queue.tap()
        XCTAssertFalse(queue.isSelected)
        XCTAssertFalse(queueScroll.exists)
        app.buttons["收起播放器"].tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 8))
    }

    func testNonControlTapsCollapsePlayer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()
        let mini = app.descendants(matching: .any)["mini-player"]
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        // Cover coordinates target the actual image, not just the page margin.
        for region in ["artwork", "title", "background", "handle"] {
            mini.tap()
            let player = app.descendants(matching: .any)["now-playing"]
            XCTAssertTrue(player.waitForExistence(timeout: 8))
            sleep(1)
            let artwork = player.descendants(matching: .any)["now-playing-artwork"]
            XCTAssertTrue(artwork.exists)
            switch region {
            case "artwork":
                artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
            case "title":
                // SwiftUI can export both title endpoints during presentation;
                // target the visible text rather than requiring a unique label.
                let title = artwork.staticTexts.matching(NSPredicate(
                    format: "label == %@ AND hittable == true", "Apologize")).firstMatch
                XCTAssertTrue(title.exists)
                title.tap()
            case "background":
                player.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
            default:
                player.buttons["收起播放器"].tap()
            }
            let collapsed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: player)
            wait(for: [collapsed], timeout: 8)
            XCTAssertTrue(mini.isHittable, "Tap on \(region) must collapse to the mini player")
        }
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
            let mini = app.descendants(matching: .any)["mini-player"]
            XCTAssertTrue(mini.exists)
            // Use the List's existing accessibility node. NavigationStack
            // does not export a decorative SwiftUI clipping wrapper as a node.
            let surface = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == %@ OR identifier == %@", "collection-list", "playlist-detail"
            )).firstMatch
            XCTAssertTrue(surface.waitForExistence(timeout: 8))
            // A second subtraction of the tab host's bottom inset leaves a
            // large black gap above the mini player despite passing navigation.
            XCTAssertGreaterThanOrEqual(surface.frame.maxY, mini.frame.minY - 8)
            XCTAssertTrue(mini.isHittable)
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
        let album = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "album-card-")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 8))
        album.tap()
        let albumList = app.descendants(matching: .any)["collection-list"]
        XCTAssertTrue(albumList.waitForExistence(timeout: 8))
        save("album-continuity")
        albumList.swipeUp()
        save("album-scrolled-continuity")
        try assertCollectionBackground(albumList)
        app.buttons["detail-card-back"].tap()
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

    func testMiniGlassAcrossRemainingTabs() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()
        let mini = app.descendants(matching: .any)["mini-player"]
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        for (tab, name) in [("收藏", "favorites-glass"), ("搜索", "search-glass")] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(mini.waitForExistence(timeout: 8))
            XCTAssertTrue(mini.isHittable)
            save(name)
        }
    }

    /// The fixture's cover yields a blue page. Sample the empty leading margin
    /// at several track rows: an opaque system black row must fail even if all
    /// navigation and playback interactions pass.
    private func assertCollectionBackground(_ list: XCUIElement) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let uiImage = try XCTUnwrap(UIImage(data: screenshot.pngRepresentation))
        let image = try XCTUnwrap(uiImage.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let screen = XCUIApplication().frame
        let scaleX = CGFloat(image.width) / screen.width
        let scaleY = CGFloat(image.height) / screen.height
        var samples: [[UInt8]] = []
        for fraction in [CGFloat(0.35), 0.5, 0.65] {
            let x = Int((list.frame.minX + 4) * scaleX)
            let y = Int((list.frame.minY + list.frame.height * fraction) * scaleY)
            let offset = (y * image.width + x) * 4
            let rgb = Array(pixels[offset..<(offset + 3)])
            XCTAssertGreaterThan(rgb[2], 20, "System black row masks the sampled blue page at \(fraction)")
            samples.append(rgb)
        }
        for sample in samples.dropFirst() {
            for channel in 0..<3 {
                XCTAssertEqual(Double(sample[channel]), Double(samples[0][channel]), accuracy: 3,
                               "Collection background changes between rows")
            }
        }
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
