import XCTest
import UIKit

final class GlassScreenshots: XCTestCase {
    func testCaptureGlassScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["library-home"].waitForExistence(timeout: 20))
        _ = try readyMini(in: app)
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

        try tapMini(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["now-playing"].waitForExistence(timeout: 8))
        sleep(1)
        save("now-playing")
    }

    func testProgressHitAreaAndPanelSelection() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()
        try tapMini(in: app)
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
        _ = try readyMini(in: app)
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
            // Use the retry-hardened tap: a raw mini.tap() loses the first
            // tap when the player is still appearing (run 40987569389 :125,
            // now-playing 8 s timeout), while tapMini retries within the
            // same 8 s budget.
            try tapMini(in: app)
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
                let title = try XCTUnwrap(artwork.staticTexts.matching(
                    identifier: "Apologize").allElementsBoundByIndex.first { $0.isHittable })
                title.tap()
            case "background":
                player.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
            default:
                player.buttons["收起播放器"].tap()
            }
            let collapsed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: player)
            wait(for: [collapsed], timeout: 8)
            // Assert hittability on a freshly stabilized element, not on the
            // test-start snapshot: the collapse transition can leave the
            // stale resolution facing a transiently invalid frame.
            let freshMini = try readyMini(in: app)
            XCTAssertTrue(freshMini.isHittable, "Tap on \(region) must collapse to the mini player")
        }
    }

    func testPlayerPullDownThreshold() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()
        try tapMini(in: app)
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
        _ = try readyMini(in: app)
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
        try tapMini(in: app)
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
        try tapMini(in: app)
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
        try checkRepeatedCardReturn(app, cell: album)
        app.tabBars.buttons["歌单"].tap()
        let playlist = app.buttons["playlist-深夜"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 8))
        try checkRepeatedCardReturn(app, cell: playlist)
    }

    private func checkRepeatedCardReturn(_ app: XCUIApplication, cell: XCUIElement) throws {
        let slot = cell.frame
        for _ in 0..<2 {
            cell.tap()
            let back = app.buttons["detail-card-back"]
            XCTAssertTrue(back.waitForExistence(timeout: 8))
            let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: back)
            wait(for: [hittable], timeout: 8)
            XCTAssertTrue(app.tabBars.buttons["歌单"].isHittable)
            let mini = try readyMini(in: app)
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
            let freshMini = try readyMini(in: app)
            XCTAssertTrue(freshMini.isHittable)
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
        _ = try readyMini(in: app)
        for (tab, name) in [("收藏", "favorites-glass"), ("搜索", "search-glass")] {
            app.tabBars.buttons[tab].tap()
            let mini = try readyMini(in: app)
            let freshMini = try readyMini(in: app)
            XCTAssertTrue(freshMini.isHittable)
            save(name)
        }
    }

    func testNativeBottomAccessoryHasOneMiniAcrossScrollAndReturn() throws {
        try checkNativeBottomAccessory(appearance: "Light")
    }

    func testDarkMinimizedNativeBottomAccessory() throws {
        try checkNativeBottomAccessory(appearance: "Dark")
    }

    private func checkNativeBottomAccessory(appearance: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotMode", "-scrollableScreenshotLibrary", "-AppleInterfaceStyle", appearance]
        app.launch()
        defer { app.terminate() }
        let songs = app.buttons["歌曲"]
        XCTAssertTrue(songs.waitForExistence(timeout: 20))
        songs.tap()
        let list = app.descendants(matching: .any)["songs-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 8))
        let minis = app.windows.descendants(matching: .any).matching(identifier: "mini-player")
        let mini = try readyMini(in: app)
        let wideHeight = mini.frame.height
        XCTAssertGreaterThanOrEqual(wideHeight, 55)
        for _ in 0..<2 {
            for upward in [true, false] {
                if upward { list.swipeUp() } else { list.swipeDown() }
                _ = try readyMini(in: app)
                XCTAssertEqual(minis.count, 1, "Native minimization must retain one mini owner")
                XCTAssertEqual(app.tabBars.count, 1)
                // A screenshot labelled inline must actually exercise inline.
                // MiniPlayer's explicit compact frame is 36 pt (wide >=56).
                let compact = NSPredicate { _, _ in minis.firstMatch.frame.height < 45 }
                let wide = NSPredicate { _, _ in minis.firstMatch.frame.height >= 55 }
                // The scroll gesture itself can be lost on a slow simulator
                // (run 40987569389 and run 40993662408 both saw this placement
                // wait time out after a swipe down). Retry the GESTURE once
                // with a non-recording wait first; the final gate is still
                // the same 5 s wait on the same predicate, so a genuinely
                // unmoved accessory still fails exactly as before.
                let firstPlacement = XCTNSPredicateExpectation(predicate: upward ? compact : wide, object: nil)
                if XCTWaiter.wait(for: [firstPlacement], timeout: 5) != .completed {
                    if upward { list.swipeUp() } else { list.swipeDown() }
                    _ = try readyMini(in: app)
                }
                let placement = XCTNSPredicateExpectation(predicate: upward ? compact : wide, object: nil)
                wait(for: [placement], timeout: 5)
                let freshMini = try readyMini(in: app)
                XCTAssertTrue(freshMini.isHittable)
                save("\(appearance.lowercased())-" + (upward ? "bottom-inline-single-owner" : "bottom-expanded-single-owner"))
            }
        }
        try tapMini(in: app)
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 8))
        app.buttons["收起播放器"].tap()
        _ = try readyMini(in: app)
        XCTAssertTrue(minis.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(minis.count, 1, "Landing must return ownership to the accessory")
        save("\(appearance.lowercased())-bottom-return")
        // These captures prove placement and ownership only. A uniform backing
        // cannot reveal material transmission; device checks use varied content.
    }

    /// The native accessory can exist before XCTest exports its screen frame.
    /// Resolve through the window host and wait before reading geometry or tapping.
    ///
    /// Do not evaluate isHittable inside this wait. XCTest resolves isHittable
    /// through the accessibility snapshot, and a transiently invalid frame
    /// (seen during scroll/expand/collapse transitions) raises "Failed to
    /// determine hittability" as a fatal error instead of returning false.
    /// The old frame guard could not prevent that: frame and isHittable are
    /// separate snapshot queries, so the frame can be valid at the guard and
    /// invalid at the isHittable evaluation. Instead, wait for a STABLE
    /// frame — two consecutive reads, 0.25 s apart, that are finite,
    /// nonempty, and equal — within the same 20 s budget. Callers still
    /// assert hittability on the returned, settled element.
    private func readyMini(in app: XCUIApplication, file: StaticString = #filePath,
                           line: UInt = #line) throws -> XCUIElement {
        let mini = app.windows.descendants(matching: .any)
            .matching(identifier: "mini-player").firstMatch
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while ProcessInfo.processInfo.systemUptime < deadline {
            if mini.exists {
                let first = mini.frame
                if isValidMiniFrame(first) {
                    Thread.sleep(forTimeInterval: 0.25)
                    let second = mini.frame
                    if second == first {
                        return mini
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return try XCTUnwrap(nil as XCUIElement?,
                            "Mini accessory must have a finite, nonempty, stable frame",
                            file: file, line: line)
    }

    private func isValidMiniFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

    private func tapMini(in app: XCUIApplication, file: StaticString = #filePath,
                         line: UInt = #line) throws {
        let mini = try readyMini(in: app, file: file, line: line)
        // Use the ready frame's center instead of the accessory's AX activation point.
        let firstTapTime = ProcessInfo.processInfo.systemUptime
        mini.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let player = app.descendants(matching: .any)["now-playing"]
        if !player.waitForExistence(timeout: 2) {
            let freshMini = try readyMini(in: app, file: file, line: line)
            freshMini.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let remaining = max(0, 8 - (ProcessInfo.processInfo.systemUptime - firstTapTime))
            XCTAssertTrue(player.waitForExistence(timeout: remaining), file: file, line: line)
        }
    }

    /// Sample empty row margins: the blue cover wash must remain visible.
    /// Spatial variation is intentional; equal colors between rows would now
    /// incorrectly require the flat plate that the wash replaces.
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
        for fraction in [CGFloat(0.35), 0.5, 0.65] {
            let x = Int((list.frame.minX + 4) * scaleX)
            let y = Int((list.frame.minY + list.frame.height * fraction) * scaleY)
            let offset = (y * image.width + x) * 4
            let rgb = Array(pixels[offset..<(offset + 3)])
            XCTAssertGreaterThan(rgb[2], 20, "System black row masks the sampled blue page at \(fraction)")
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
