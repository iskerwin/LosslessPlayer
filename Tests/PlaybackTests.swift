import XCTest
import UIKit
import CoreGraphics
import AVFoundation
@testable import LosslessPlayer

final class PlaybackQueueTests: XCTestCase {
    func testQueueBoundariesAndMissingCurrent() {
        let a = UUID(), b = UUID(), c = UUID()
        var queue = PlaybackQueue(ids: [a, b, c], repeatAll: false)
        XCTAssertEqual(queue.next(after: a), b)
        XCTAssertNil(queue.next(after: c))
        XCTAssertNil(queue.next(after: a, backwards: true))
        XCTAssertEqual(queue.next(after: UUID()), a)
        queue.repeatAll = true
        XCTAssertEqual(queue.next(after: c), a)
        XCTAssertEqual(queue.next(after: a, backwards: true), c)
        XCTAssertNil(PlaybackQueue().next(after: nil))
    }

    func testShuffleRestoresContextAndKeepsEnqueuedTail() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var ordering = QueueOrdering(queue: [b, c, a, d], context: [a, b, c], shuffle: true)
        ordering.toggleShuffle(current: b)
        XCTAssertFalse(ordering.shuffle)
        XCTAssertEqual(ordering.queue, [a, b, c, d])
    }

    func testEnablingShuffleKeepsCurrentFirstAndRemembersContext() {
        let a = UUID(), b = UUID(), c = UUID()
        var ordering = QueueOrdering(queue: [a, b, c], context: [], shuffle: false)
        ordering.toggleShuffle(current: b)
        XCTAssertTrue(ordering.shuffle)
        XCTAssertEqual(ordering.context, [a, b, c])
        XCTAssertEqual(ordering.queue.first, b)
        XCTAssertEqual(Set(ordering.queue), Set([a, b, c]))
        ordering.toggleShuffle(current: b)
        XCTAssertEqual(ordering.queue, [a, b, c])
    }

    func testShuffledPlayRestoresListOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        var ordering = QueueOrdering()
        ordering.applyPlay(orderedIDs: [a, b, c], queue: [c, a, b], shuffle: true)
        XCTAssertTrue(ordering.shuffle)
        XCTAssertEqual(ordering.context, [a, b, c])
        ordering.toggleShuffle(current: c)
        XCTAssertFalse(ordering.shuffle)
        XCTAssertEqual(ordering.queue, [a, b, c])
    }

    func testFirstPlayableSkipsMissingTracks() {
        var missing = Track(id: UUID(), filename: "a.wav", title: "A", artist: "X", album: "Y", duration: 1, sampleRate: 44100, bitDepth: 16)
        missing.missing = true
        let playable = Track(id: UUID(), filename: "b.wav", title: "B", artist: "X", album: "Y", duration: 1, sampleRate: 44100, bitDepth: 16)
        XCTAssertEqual([missing, playable].firstPlayable()?.id, playable.id)
        XCTAssertNil([missing].firstPlayable())
    }

    func testRemovalNoticeMatchesDeleteBehavior() {
        var imported = Track(id: UUID(), filename: "a.wav", title: "A", artist: "X", album: "Y", duration: 1, sampleRate: 44100, bitDepth: 16)
        var indexed = imported
        indexed.folderID = UUID()
        XCTAssertTrue(RemovalNotice.deletesAppCopy(imported))
        XCTAssertFalse(RemovalNotice.deletesAppCopy(indexed))
        XCTAssertTrue(RemovalNotice.message(for: imported).contains("副本"))
        XCTAssertTrue(RemovalNotice.message(for: indexed).contains("不会删除"))
        XCTAssertNotEqual(RemovalNotice.title(for: imported), RemovalNotice.title(for: indexed))
    }

    func testPlaybackContextMatchesTheWholeList() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertTrue(PlaybackContext.matches(list: [a, b], context: [b, a]))
        XCTAssertFalse(PlaybackContext.matches(list: [a, b], context: [a, b, c]))
        XCTAssertFalse(PlaybackContext.matches(list: [a], context: [a, b]))
        XCTAssertFalse(PlaybackContext.matches(list: [], context: []))
        XCTAssertFalse(PlaybackContext.matches(list: [], context: [a]))
    }

    func testListCapsulesStayStateless() {
        XCTAssertEqual(CollectionTransport.allCases.map(\.title), ["播放", "随机播放"])
        XCTAssertEqual(CollectionTransport.allCases.map(\.symbol), ["play.fill", "shuffle"])
        XCTAssertTrue(CollectionTransport.allCases.allSatisfy { !$0.reflectsPlaybackState })
        let symbols = Set(CollectionTransport.allCases.map(\.symbol))
        XCTAssertFalse(symbols.contains("pause.fill"))
        XCTAssertFalse(symbols.contains("repeat"))
        XCTAssertFalse(symbols.contains("repeat.1"))
    }

    func testNowPlayingTransportReflectsGlobalShuffleAndRepeat() {
        let playing = NowPlayingTransport.state(playing: true, shuffle: true, repeatMode: .one)
        XCTAssertEqual(playing.playSymbol, "pause.fill")
        XCTAssertEqual(playing.playTitle, "暂停")
        XCTAssertTrue(playing.playHighlighted)
        XCTAssertTrue(playing.shuffleHighlighted)
        XCTAssertEqual(playing.repeatSymbol, "repeat.1")
        XCTAssertEqual(playing.repeatTitle, "单曲")
        XCTAssertTrue(playing.repeatHighlighted)

        let paused = NowPlayingTransport.state(playing: false, shuffle: false, repeatMode: .off)
        XCTAssertEqual(paused.playSymbol, "play.fill")
        XCTAssertEqual(paused.playTitle, "播放")
        XCTAssertFalse(paused.playHighlighted)
        XCTAssertFalse(paused.shuffleHighlighted)
        XCTAssertEqual(paused.repeatSymbol, "repeat")
        XCTAssertEqual(paused.repeatTitle, "循环")
        XCTAssertFalse(paused.repeatHighlighted)

        let looping = NowPlayingTransport.state(playing: false, shuffle: false, repeatMode: .all)
        XCTAssertEqual(looping.repeatTitle, "列表")
        XCTAssertTrue(looping.repeatHighlighted)
        XCTAssertFalse(looping.shuffleHighlighted)
    }

    func testQualityBadgeAndDarkArtworkPalette() {
        let lossless = Track(id: UUID(), filename: "a.flac", title: "A", artist: "X", album: "Y", duration: 1, sampleRate: 48000, bitDepth: 24)
        let mp3 = Track(id: UUID(), filename: "b.mp3", title: "B", artist: "X", album: "Y", duration: 1, sampleRate: 44100, bitDepth: 0)
        XCTAssertEqual(lossless.qualityBadge, "Lossless")
        XCTAssertEqual(mp3.qualityBadge, "MP3")
        var brightness: CGFloat = 1
        let dark = ArtworkColors.darkened(UIColor(hue: 0.6, saturation: 0.9, brightness: 1, alpha: 1))
        XCTAssertTrue(dark.getHue(nil, saturation: nil, brightness: &brightness, alpha: nil))
        XCTAssertLessThanOrEqual(brightness, 0.36)
        XCTAssertEqual(ScrubberMap.fraction(value: 4, in: 0...211), 4 / 211, accuracy: 0.0001)
        XCTAssertEqual(ScrubberMap.value(x: 50, width: 100, in: 0...10), 5, accuracy: 0.0001)
    }

    func testBlankRowAreaPlaysAndEllipsisStaysMenu() {
        let width: CGFloat = 390
        let menu = RowMetrics.menuWidth
        XCTAssertEqual(RowHitMap.zone(x: 0, width: width, menuWidth: menu), .play)
        XCTAssertEqual(RowHitMap.zone(x: width * 0.7, width: width, menuWidth: menu), .play)
        XCTAssertEqual(RowHitMap.zone(x: width - menu - 1, width: width, menuWidth: menu), .play)
        XCTAssertEqual(RowHitMap.zone(x: width - menu, width: width, menuWidth: menu), .menu)
        XCTAssertEqual(RowHitMap.zone(x: width - 1, width: width, menuWidth: menu), .menu)
        XCTAssertEqual(RowHitMap.zone(x: 12, width: 0, menuWidth: menu), .play)
        XCTAssertEqual(RowHitMap.zone(x: width - 4, width: width, menuWidth: 0), .play)
    }

    func testScrubberClampsEndpointsAndRejectsNonFiniteGeometry() {
        XCTAssertEqual(ScrubberMap.fraction(value: -1, in: 0...211), 0)
        XCTAssertEqual(ScrubberMap.fraction(value: 300, in: 0...211), 1)
        XCTAssertEqual(ScrubberMap.fraction(value: .nan, in: 0...211), 0)
        XCTAssertEqual(ScrubberMap.fraction(value: 4, in: 0...0), 0)
        XCTAssertEqual(ScrubberMap.fraction(value: 4, in: 0...Double.infinity), 0)
        XCTAssertEqual(ScrubberMap.value(x: -20, width: 100, in: 5...15), 5)
        XCTAssertEqual(ScrubberMap.value(x: 120, width: 100, in: 5...15), 15)
        XCTAssertEqual(ScrubberMap.value(x: 50, width: 0, in: 5...15), 5)
        XCTAssertEqual(ScrubberMap.value(x: .nan, width: 100, in: 5...15), 5)
        XCTAssertEqual(ScrubberMap.value(x: 50, width: .infinity, in: 5...15), 5)
    }

    func testPlayNextInsertsAfterCurrentAndAddToQueueAppends() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        var ordering = QueueOrdering(queue: [a, b, c], context: [a, b, c], shuffle: false)
        ordering.insert([d, e], after: b, next: true)
        XCTAssertEqual(ordering.queue, [a, b, d, e, c])
        XCTAssertEqual(ordering.context, [a, b, d, e, c])
        ordering.insert([d], after: b, next: false)
        XCTAssertEqual(ordering.queue, [a, b, e, c, d])
        XCTAssertEqual(ordering.context, [a, b, e, c, d])
    }

    func testPlayNextWhileShuffledStaysImmediatelyAfterCurrent() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var ordering = QueueOrdering(queue: [b, c, a], context: [a, b, c], shuffle: true)
        ordering.insert([d], after: b, next: true)
        XCTAssertEqual(ordering.queue, [b, d, c, a])
        XCTAssertEqual(ordering.context, [a, b, d, c])
        ordering.toggleShuffle(current: b)
        XCTAssertFalse(ordering.shuffle)
        XCTAssertEqual(ordering.queue, [a, b, d, c])
    }

    func testEnqueueSkipsTheCurrentTrackAndDuplicates() {
        let a = UUID(), b = UUID(), c = UUID()
        var ordering = QueueOrdering(queue: [a, b, c], context: [a, b, c], shuffle: false)
        ordering.insert([b], after: b, next: true)
        XCTAssertEqual(ordering.queue, [a, b, c])
        ordering.insert([c, c], after: a, next: true)
        XCTAssertEqual(ordering.queue, [a, c, b])
        XCTAssertEqual(ordering.context, [a, c, b])
    }

    func testSongMenuUsesLibraryLabelsAndHidesMissingLyrics() {
        var track = Track(id: UUID(), filename: "a.wav", title: "A", artist: "X", album: "Y", duration: 1, sampleRate: 44100, bitDepth: 16)
        let plain = SongMenuCatalog.groups(for: track, handlers: .ignore).flatMap(\.entries).map(\.title)
        XCTAssertEqual(plain, ["收藏", "添加到歌单", "下一首播放", "稍后播放", "前往专辑", "前往艺术家", "从资料库中删除"])
        XCTAssertFalse(plain.contains("查看完整歌词"))
        track.lyrics = "  hello  "
        track.favorite = true
        var handlers = SongHandlers.ignore
        handlers.setCover = { _ in }
        handlers.removeFromPlaylist = { _ in }
        let loved = SongMenuCatalog.groups(for: track, handlers: handlers).flatMap(\.entries).map(\.title)
        XCTAssertEqual(loved, ["取消收藏", "添加到歌单", "下一首播放", "稍后播放", "前往专辑", "前往艺术家", "查看完整歌词", "设为歌单封面", "从歌单中移除", "从资料库中删除"])
        XCTAssertEqual(SongMenuModel.baseTitles.first, "收藏")
        XCTAssertEqual(SongMenuModel.baseTitles.last, "从资料库中删除")
    }

    func testBulkRemovalNoticeMentionsCopiesAndOriginals() {
        var copy = Track(id: UUID(), filename: "a.wav", title: "A", artist: "X", album: "Y", duration: 1, sampleRate: 44100, bitDepth: 16)
        var indexed = copy
        indexed.id = UUID()
        indexed.folderID = UUID()
        XCTAssertEqual(RemovalNotice.title(for: [copy]), RemovalNotice.title(for: copy))
        let mixed = RemovalNotice.message(for: [copy, indexed])
        XCTAssertTrue(mixed.contains("副本"))
        XCTAssertTrue(mixed.contains("原文件"))
        XCTAssertTrue(RemovalNotice.message(for: [copy, copy]).contains("副本"))
        XCTAssertFalse(RemovalNotice.message(for: [indexed, indexed]).contains("副本"))
    }

    func testRepeatModeCyclesBetweenOffListAndOne() {
        XCTAssertEqual(RepeatMode.off.cycled, .all)
        XCTAssertEqual(RepeatMode.all.cycled, .one)
        XCTAssertEqual(RepeatMode.one.cycled, .off)
        XCTAssertEqual(RepeatMode.off.symbolName, "repeat")
        XCTAssertEqual(RepeatMode.all.symbolName, "repeat")
        XCTAssertEqual(RepeatMode.one.symbolName, "repeat.1")
        XCTAssertNotEqual(RepeatMode.all.symbolName, RepeatMode.one.symbolName)
    }

    func testSelectAllKeepsHiddenChoicesWhenTheFilterChanges() {
        let ada = UUID(), bea = UUID(), cy = UUID()
        var selected = VisibleSongSelection.selectVisible([ada, bea], in: [])
        XCTAssertEqual(selected, Set([ada, bea]))
        selected = VisibleSongSelection.selectVisible([cy], in: selected)
        XCTAssertEqual(selected, Set([ada, bea, cy]))
        selected = VisibleSongSelection.deselectVisible([bea], in: selected)
        XCTAssertEqual(selected, Set([ada, cy]))
        XCTAssertTrue(VisibleSongSelection.allVisibleSelected([ada], in: selected))
        XCTAssertFalse(VisibleSongSelection.allVisibleSelected([ada, bea], in: selected))
        XCTAssertTrue(VisibleSongSelection.anyVisibleSelected([bea, cy], in: selected))
        XCTAssertFalse(VisibleSongSelection.anyVisibleSelected([bea], in: selected))
        XCTAssertFalse(VisibleSongSelection.allVisibleSelected([], in: selected))
    }

    func testRelativePathUsesCoordinatedRootDespitePrivatePrefix() {
        let root = URL(fileURLWithPath: "/var/mobile/Containers/Music")
        let coordinated = URL(fileURLWithPath: "/private/var/mobile/Containers/Music/")
        let file = URL(fileURLWithPath: "/private/var/mobile/Containers/Music/Album/01.flac")
        XCTAssertEqual(AudioScanner.relativePath(for: file, in: root), "Album/01.flac")
        XCTAssertEqual(AudioScanner.relativePath(for: file, in: coordinated), "Album/01.flac")
        let provider = URL(fileURLWithPath: "/private/var/mobile/Library/LiveFiles/ABC/Music")
        let provided = URL(fileURLWithPath: "/var/mobile/Library/LiveFiles/ABC/Music/Live/02.wav")
        XCTAssertEqual(AudioScanner.relativePath(for: provided, in: provider), "Live/02.wav")
        XCTAssertNil(AudioScanner.relativePath(for: URL(fileURLWithPath: "/private/var/mobile/Other/01.flac"), in: root))
        let composed = URL(fileURLWithPath: "/var/mobile/Containers/Music/Album/\u{0065}\u{0301}.flac")
        XCTAssertEqual(AudioScanner.relativePath(for: composed, in: URL(fileURLWithPath: "/private/var/mobile/Containers/Music")), "Album/\u{00e9}.flac")
    }
}

@MainActor
final class LibraryTests: XCTestCase {
    func testImportFavoriteRestoreAndDeletePreservesSource() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("Test Tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
        buffer.frameLength = 4410
        for channel in 0..<2 {
            for frame in 0..<4410 { buffer.floatChannelData![channel][frame] = 0 }
        }
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        let root = base.appendingPathComponent("Library")
        let library = LibraryStore(root: root)
        await library.importFiles([source])
        XCTAssertNil(library.errorMessage)
        let track = try XCTUnwrap(library.tracks.first)
        XCTAssertEqual(track.title, "Test Tone")
        XCTAssertEqual(track.sampleRate, 44100)
        XCTAssertEqual(track.duration, 0.1, accuracy: 0.001)
        library.toggleFavorite(track)
        XCTAssertTrue(RemovalNotice.deletesAppCopy(track))
        library.remember(id: track.id, position: 0.05)
        let restored = LibraryStore(root: root)
        XCTAssertEqual(restored.tracks.first?.favorite, true)
        XCTAssertEqual(restored.playback.currentID, track.id)
        XCTAssertEqual(restored.playback.position, 0.05)
        restored.remove(track)
        XCTAssertTrue(restored.tracks.isEmpty)
        XCTAssertNil(restored.playback.currentID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.url(for: track).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(LibraryStore(root: root).tracks.isEmpty)
    }

    func testUnsupportedFileDoesNotPolluteLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let source = root.appendingPathComponent("bad.flac")
        try Data("invalid".utf8).write(to: source)
        await library.importFiles([source])
        XCTAssertTrue(library.tracks.isEmpty)
        XCTAssertNotNil(library.errorMessage)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["bad.flac"])
    }

    func testPlaybackProgressDoesNotRewriteLibraryFile() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
        buffer.frameLength = 4410
        for channel in 0..<2 { for frame in 0..<4410 { buffer.floatChannelData![channel][frame] = 0 } }
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        let root = base.appendingPathComponent("Library")
        let library = LibraryStore(root: root)
        await library.importFiles([source])
        let track = try XCTUnwrap(library.tracks.first)
        let libraryURL = root.appendingPathComponent("library.json")
        let before = try Data(contentsOf: libraryURL)
        library.remember(id: track.id, position: 4)
        library.rememberQueue([track.id], contextOrder: [track.id], shuffle: true)
        library.rememberTransport(shuffle: true, repeatMode: .one)
        XCTAssertEqual(try Data(contentsOf: libraryURL), before)
        let playbackURL = root.appendingPathComponent("playback.json")
        let playback = try Data(contentsOf: playbackURL)
        XCTAssertLessThan(playback.count, before.count)
        let restored = LibraryStore(root: root)
        XCTAssertEqual(restored.playback.currentID, track.id)
        XCTAssertEqual(restored.playback.position, 4)
        XCTAssertEqual(restored.playback.queueIDs, [track.id])
        XCTAssertEqual(restored.playback.contextOrder, [track.id])
        XCTAssertTrue(restored.playback.shuffle)
        XCTAssertEqual(restored.playback.repeatMode, .one)
        XCTAssertNotEqual(restored.playback, PlaybackState())
    }

    func testLegacyLibraryPlaybackMigratesIntoPlaybackFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let json = #"{"tracks":[],"currentID":"\#(id.uuidString)","position":3.5,"queueIDs":["\#(id.uuidString)"]}"#
        try Data(json.utf8).write(to: root.appendingPathComponent("library.json"))
        let library = LibraryStore(root: root)
        XCTAssertEqual(library.playback.currentID, id)
        XCTAssertEqual(library.playback.position, 3.5, accuracy: 0.001)
        XCTAssertEqual(library.playback.queueIDs, [id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("playback.json").path))
        XCTAssertEqual(LibraryStore(root: root).playback.currentID, id)
    }

    func testStaleBookmarkRefreshesAndFreshBookmarkStays() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Music")
        let nested = folder.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let library = LibraryStore(root: base.appendingPathComponent("Index"))
        await library.addFolder(folder)
        let id = try XCTUnwrap(library.snapshot.folders.first?.id)
        let before = try XCTUnwrap(library.snapshot.folders.first?.bookmark)
        library.noteResolvedBookmark(for: id, url: nested, stale: false)
        XCTAssertEqual(library.snapshot.folders.first?.bookmark, before)
        library.noteResolvedBookmark(for: id, url: nested, stale: true)
        let after = try XCTUnwrap(library.snapshot.folders.first?.bookmark)
        XCTAssertNotEqual(after, before)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: after, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertEqual(resolved.standardizedFileURL, nested.standardizedFileURL)
    }
}

final class MigrationAndLyricsTests: XCTestCase {
    func testOldLibraryWithoutFolderAndPlaylistFieldsMigrates() throws {
        let old = Data(#"{"tracks":[],"position":12.5}"#.utf8)
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: old)
        XCTAssertTrue(snapshot.folders.isEmpty)
        XCTAssertTrue(snapshot.playlists.isEmpty)
        XCTAssertTrue(snapshot.queueIDs.isEmpty)
        XCTAssertEqual(snapshot.position, 12.5)
    }
    func testTimedLyricsMultipleTagsAndMetadata() {
        let lines = LyricsLine.parse("[ar:Artist]\n[00:02.50][01:03.125]Hello\n[00:01.00]First")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.map(\.time), [1, 2.5, 63.125])
        XCTAssertEqual(lines.map(\.text), ["First", "Hello", "Hello"])
    }
}

@MainActor
final class FolderScanTests: XCTestCase {
    private func wav(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
        buffer.frameLength = 4410
        for channel in 0..<2 { for frame in 0..<4410 { buffer.floatChannelData![channel][frame] = 0 } }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    func testRecursiveIncrementalScanPreservesIDsFavoritesPlaylistsAndSource() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Music")
        let first = folder.appendingPathComponent("Album/01.wav")
        try wav(first)
        try Data("not music".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try wav(folder.appendingPathComponent(".hidden.wav"))
        let library = LibraryStore(root: base.appendingPathComponent("Index"))
        await library.addFolder(folder)
        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(library.tracks.count, 1)
        let track = try XCTUnwrap(library.tracks.first)
        let source = try XCTUnwrap(library.snapshot.folders.first)
        XCTAssertEqual(track.relativePath, "Album/01.wav")
        XCTAssertEqual(library.url(for: track).standardizedFileURL, first.standardizedFileURL)
        library.toggleFavorite(track)
        library.createPlaylist("Test")
        let playlist = try XCTUnwrap(library.snapshot.playlists.first)
        library.add(track, to: playlist)
        library.add(track, to: playlist)
        // Add sidecar lyrics without changing audio file: rescan must still see them.
        try "[00:00.00]Test lyrics".write(to: first.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
        await library.scanFolder(source.id)
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertEqual(library.tracks.first?.id, track.id)
        XCTAssertEqual(library.tracks.first?.favorite, true)
        XCTAssertEqual(library.tracks.first?.lyrics, "[00:00.00]Test lyrics")
        XCTAssertEqual(library.snapshot.playlists.first?.trackIDs, [track.id])
        // New file in nested directory and disappearance of an old file.
        try wav(folder.appendingPathComponent("Other/02.wav"))
        try FileManager.default.moveItem(at: first, to: base.appendingPathComponent("moved.wav"))
        await library.scanFolder(source.id)
        XCTAssertEqual(library.tracks.count, 2)
        XCTAssertEqual(library.tracks.first { $0.id == track.id }?.missing, true)
        // Loss of folder access must never mark all entries as deleted.
        try FileManager.default.moveItem(at: folder, to: base.appendingPathComponent("Unavailable"))
        await library.scanFolder(source.id)
        XCTAssertEqual(library.tracks.count, 2)
        let restored = LibraryStore(root: library.root)
        XCTAssertEqual(restored.tracks.count, 2)
        restored.removeFolder(source)
        XCTAssertTrue(restored.tracks.isEmpty)
        XCTAssertTrue(restored.snapshot.folders.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("moved.wav").path))
    }
    func testRemovedIndexedTrackStaysExcludedAndOriginalIsNeverDeleted() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Source")
        let audio = folder.appendingPathComponent("song.wav")
        try wav(audio)
        let library = LibraryStore(root: base.appendingPathComponent("Index"))
        await library.addFolder(folder)
        let track = try XCTUnwrap(library.tracks.first)
        XCTAssertFalse(RemovalNotice.deletesAppCopy(track))
        let id = try XCTUnwrap(library.snapshot.folders.first?.id)
        library.remove(track)
        await library.scanFolder(id)
        XCTAssertTrue(library.tracks.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }
    func testToggleStartsFirstAvailableTrack() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Music")
        try wav(folder.appendingPathComponent("a.wav"))
        try wav(folder.appendingPathComponent("b.wav"))
        let library = LibraryStore(root: base.appendingPathComponent("Index"))
        await library.addFolder(folder)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.wav"))
        let id = try XCTUnwrap(library.snapshot.folders.first?.id)
        await library.scanFolder(id)
        XCTAssertEqual(library.tracks.first { $0.relativePath == "a.wav" }?.available, false)
        XCTAssertEqual(library.tracks.firstPlayable()?.relativePath, "b.wav")
        let player = PlayerStore(library: library)
        player.toggle()
        XCTAssertEqual(player.current?.relativePath, "b.wav")
    }
    func testCopiedImportDeduplicatesIdenticalContentAndFolderAuthorization() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Source")
        let audio = folder.appendingPathComponent("song.wav")
        try wav(audio)
        let duplicate = folder.appendingPathComponent("renamed.wav")
        try FileManager.default.copyItem(at: audio, to: duplicate)
        let library = LibraryStore(root: base.appendingPathComponent("Index"))
        try "[00:00.00]Imported lyrics".write(to: audio.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
        await library.importFiles([audio, duplicate])
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertEqual(library.tracks.first?.lyrics, "[00:00.00]Imported lyrics")
        await library.addFolder(folder)
        await library.addFolder(folder)
        XCTAssertEqual(library.snapshot.folders.count, 1)
        XCTAssertEqual(library.tracks.filter { $0.folderID != nil }.count, 2)
    }
    func testCancelledScanDoesNotCommitPartialLibrary() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Source")
        try wav(folder.appendingPathComponent("song.wav"))
        let library = LibraryStore(root: base.appendingPathComponent("Index"))
        await library.addFolder(folder)
        let id = try XCTUnwrap(library.snapshot.folders.first?.id)
        let before = library.tracks
        let task = Task { await library.scanFolder(id) }
        task.cancel()
        await task.value
        XCTAssertEqual(library.tracks, before)
    }

    func testFolderArtworkIsUsedWhenAudioHasNoEmbeddedPicture() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Album")
        try wav(folder.appendingPathComponent("01.wav"))
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try png.write(to: folder.appendingPathComponent("cover.png"))
        let library = LibraryStore(root: base.appendingPathComponent("Index"))
        await library.addFolder(folder)
        let track = try XCTUnwrap(library.tracks.first)
        let artwork = try XCTUnwrap(track.artworkFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.root.appendingPathComponent(artwork).path))
        library.recordPlay(id: track.id)
        await library.scanFolder(try XCTUnwrap(library.snapshot.folders.first?.id))
        let again = try XCTUnwrap(library.tracks.first)
        XCTAssertEqual(again.playCount, 1)
        XCTAssertNotNil(again.lastPlayed)
        XCTAssertEqual(again.id, track.id)
    }
}

final class LibraryCatalogTests: XCTestCase {
    private func track(title: String, artist: String, album: String, file: String = "a.wav") -> Track {
        Track(id: UUID(), filename: file, title: title, artist: artist, album: album, duration: 1, sampleRate: 44100, bitDepth: 16)
    }

    func testCompilationAndAlbumArtistGroupIntoOneAlbum() {
        var first = track(title: "One", artist: "Ada", album: "Hits")
        var second = track(title: "Two", artist: "Bea", album: "Hits", file: "b.wav")
        first.compilation = true
        second.compilation = true
        let groups = AlbumGroup.groups([first, second])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].artist, "合辑")
        first.albumArtist = "Various Artists"
        second.albumArtist = "Various Artists"
        let named = AlbumGroup.groups([first, second])
        XCTAssertEqual(named.count, 1)
        XCTAssertEqual(named[0].artist, "Various Artists")
        var solo = track(title: "Solo", artist: "Ada", album: "Hits", file: "c.wav")
        solo.albumArtist = "Ada"
        XCTAssertEqual(AlbumGroup.groups([first, solo]).count, 2)
    }

    func testSortByPlayCountAddedDateAndAlbumOrder() {
        var early = track(title: "B", artist: "Z", album: "A", file: "b.wav")
        var later = track(title: "A", artist: "A", album: "A", file: "a.wav")
        early.addedAt = Date(timeIntervalSince1970: 10)
        later.addedAt = Date(timeIntervalSince1970: 20)
        early.playCount = 3
        later.playCount = 1
        early.discNumber = 2
        early.trackNumber = 1
        later.discNumber = 1
        later.trackNumber = 2
        XCTAssertEqual(LibrarySort.played.sorted([later, early]).map(\.title), ["B", "A"])
        XCTAssertEqual(LibrarySort.added.sorted([early, later]).map(\.title), ["A", "B"])
        XCTAssertEqual(LibrarySort.album.sorted([early, later]).map(\.title), ["A", "B"])
        XCTAssertEqual(LibrarySort.title.sorted([early, later]).map(\.title), ["A", "B"])
    }

    func testBinaryTrackAndDiscNumbersGenreAndYear() {
        XCTAssertEqual(AudioTags.number(from: "3/12"), 3)
        XCTAssertEqual(AudioTags.number(from: Data([0x00, 0x00, 0x00, 0x03, 0x00, 0x0C, 0x00, 0x00])), 3)
        XCTAssertEqual(AudioTags.number(from: Data([0x00, 0x00, 0x00, 0x02, 0x00, 0x02])), 2)
        XCTAssertEqual(AudioTags.role(for: "itsk/trkn"), .track)
        XCTAssertEqual(AudioTags.role(for: "itsk/disk"), .disc)
        XCTAssertEqual(AudioTags.role(for: "id3/TPE2"), .albumArtist)
        XCTAssertEqual(AudioTags.genre(from: "(17)"), "Rock")
        XCTAssertEqual(AudioTags.year(from: "1994-03-01"), 1994)
        XCTAssertNil(AudioTags.year(from: "March"))
        XCTAssertTrue(AudioTags.compilation(from: "1"))
    }

    func testFolderArtworkPrefersCoverOverFolder() {
        let directory = URL(fileURLWithPath: "/Music/Album")
        let chosen = FolderArtwork.url(in: directory, entries: ["notes.txt", "Folder.JPG", "cover.PNG"])
        XCTAssertEqual(chosen?.lastPathComponent, "cover.PNG")
    }

    func testM3URoundTripAndMatch() {
        var indexed = track(title: "Song", artist: "Ada", album: "Hits", file: "song.flac")
        indexed.relativePath = "Hits/song.flac"
        indexed.duration = 12.2
        let rendered = PlaylistExchange.render([indexed])
        let entries = PlaylistExchange.parse(rendered)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].artist, "Ada")
        XCTAssertEqual(entries[0].title, "Song")
        XCTAssertEqual(PlaylistExchange.match(entries[0], in: [indexed])?.id, indexed.id)
        let windows = M3UEntry(path: "C:\\Music\\Hits\\song.flac", title: nil, artist: nil, duration: nil)
        XCTAssertEqual(PlaylistExchange.match(windows, in: [indexed])?.id, indexed.id)
        let text = "#EXTM3U\n#EXTINF:5,Only Title\nmissing.wav\nplain.wav\n"
        XCTAssertEqual(PlaylistExchange.parse(text).map(\.path), ["missing.wav", "plain.wav"])
        XCTAssertEqual(PlaylistExchange.parse(text)[0].title, "Only Title")
        var short = track(title: "A", artist: "Ada", album: "Hits", file: "a.wav")
        short.relativePath = "a.wav"
        XCTAssertNil(PlaylistExchange.match(M3UEntry(path: "extra.wav", title: nil, artist: nil, duration: nil), in: [short]))
    }

    func testPlaylistCoverUsesCustomArtOrFourUpMosaic() {
        let first = track(title: "One", artist: "Ada", album: "Hits")
        let second = track(title: "Two", artist: "Bea", album: "Hits", file: "b.wav")
        let mosaic = PlaylistCover.choice(coverTrackID: nil, members: [first, second])
        XCTAssertFalse(mosaic.single)
        XCTAssertEqual(mosaic.tracks.count, 4)
        XCTAssertEqual(mosaic.tracks.compactMap { $0 }.map(\.id), [first.id, second.id])
        let custom = PlaylistCover.choice(coverTrackID: second.id, members: [first, second])
        XCTAssertTrue(custom.single)
        XCTAssertEqual(custom.tracks.compactMap { $0 }.map(\.id), [second.id])
        XCTAssertTrue(PlaylistCover.choice(coverTrackID: nil, members: [first]).single)
    }

    func testLegacyTrackAndPlaylistDecodeWithoutNewFields() throws {
        let id = UUID()
        let trackJSON = """
        {"id":"\(id.uuidString)","filename":"a.wav","title":"A","artist":"B","album":"C","duration":1.5,"sampleRate":44100,"bitDepth":16,"favorite":true}
        """
        let track = try JSONDecoder().decode(Track.self, from: Data(trackJSON.utf8))
        XCTAssertTrue(track.favorite)
        XCTAssertEqual(track.playCount, 0)
        XCTAssertNil(track.albumArtist)
        XCTAssertNil(track.genre)
        let playlist = try JSONDecoder().decode(Playlist.self, from: Data(#"{"name":"Old","trackIDs":[]}"#.utf8))
        XCTAssertEqual(playlist.name, "Old")
        XCTAssertNil(playlist.coverTrackID)
    }
}

@MainActor
final class PlaylistManagementTests: XCTestCase {
    private func wav(_ url: URL, sample: Float) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
        buffer.frameLength = 4410
        for channel in 0..<2 { for frame in 0..<4410 { buffer.floatChannelData![channel][frame] = sample } }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func testRenameReorderCoverFavoriteAndPlaylistImport() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("one.wav")
        let second = base.appendingPathComponent("two.wav")
        try wav(first, sample: 0)
        try wav(second, sample: 0.25)
        let library = LibraryStore(root: base.appendingPathComponent("Index"))
        await library.importFiles([first, second])
        XCTAssertEqual(library.tracks.count, 2)
        let tracks = library.tracks.sorted { $0.title < $1.title }
        library.toggleFavorite(tracks[0])
        XCTAssertEqual(library.tracks.filter(\.favorite).map(\.id), [tracks[0].id])
        let list = try XCTUnwrap(library.createPlaylist("Mix"))
        library.add(tracks[0], to: list)
        library.add(tracks[1], to: list)
        library.moveTracks(in: list, displayed: [tracks[0].id, tracks[1].id], from: IndexSet(integer: 0), to: 2)
        library.rename(list, to: "Evening")
        library.setCover(tracks[1], for: list)
        let saved = try XCTUnwrap(library.snapshot.playlists.first)
        XCTAssertEqual(saved.name, "Evening")
        XCTAssertEqual(saved.trackIDs, [tracks[1].id, tracks[0].id])
        XCTAssertEqual(saved.coverTrackID, tracks[1].id)
        library.recordPlay(id: tracks[1].id)
        let m3u = base.appendingPathComponent("Evening.m3u8")
        try PlaylistExchange.render(saved.trackIDs.compactMap { id in library.tracks.first { $0.id == id } }).write(to: m3u, atomically: true, encoding: .utf8)
        library.startImportPlaylists([m3u])
        XCTAssertEqual(library.snapshot.playlists.count, 2)
        XCTAssertEqual(library.snapshot.playlists.last?.trackIDs.count, 2)
        let restored = LibraryStore(root: library.root)
        XCTAssertEqual(restored.tracks.first { $0.id == tracks[1].id }?.playCount, 1)
        XCTAssertEqual(restored.tracks.filter(\.favorite).count, 1)
        XCTAssertEqual(restored.snapshot.playlists.first?.name, "Evening")
    }

    func testAddingTracksSkipsOnesAlreadyPresent() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = LibraryStore(root: base)
        let first = Track(id: UUID(), filename: "a.wav", title: "A", artist: "X", album: "Y", duration: 1, sampleRate: 44100, bitDepth: 16)
        let second = Track(id: UUID(), filename: "b.wav", title: "B", artist: "X", album: "Y", duration: 1, sampleRate: 44100, bitDepth: 16)
        let list = try XCTUnwrap(library.createPlaylist("Mix"))
        library.add([first, second, first], to: list)
        library.add(first, to: list)
        XCTAssertEqual(library.snapshot.playlists.first?.trackIDs, [first.id, second.id])
    }
}

final class AudioPathTests: XCTestCase {
    private func assess(lossless: Bool = true, source: Double = 44100, session: Double = 44100,
                        route: AudioRouteKind = .usb, volume: Float = 1.0) -> AudioPathAssessment {
        AudioPathAssessment.assess(isLosslessSource: lossless, sourceSampleRate: source,
                                   sessionSampleRate: session, route: route, digitalVolume: volume)
    }

    func testBitPerfectOnlyWhenEveryConditionHolds() {
        XCTAssertEqual(assess().level, .bitPerfectPossible)
        XCTAssertEqual(assess(source: 96000, session: 96000, route: .wired).level, .bitPerfectPossible)
    }

    func testResampledSessionIsNotBitPerfect() {
        let path = assess(source: 96000, session: 48000)
        XCTAssertEqual(path.level, .resampled)
        XCTAssertTrue(path.detail.contains("96.0 kHz"))
        XCTAssertTrue(path.detail.contains("48.0 kHz"))
    }

    func testWirelessRoutesAreNeverBitPerfect() {
        XCTAssertEqual(assess(route: .bluetooth).level, .wireless)
        XCTAssertEqual(assess(route: .airPlay).level, .wireless)
    }

    func testDigitalVolumeBelowUnityBreaksBitPerfect() {
        XCTAssertEqual(assess(volume: 0.5).level, .digitalVolume)
        XCTAssertEqual(assess(volume: 0.999).level, .bitPerfectPossible)
    }

    func testLossySourceDominatesIdealOutput() {
        XCTAssertEqual(assess(lossless: false).level, .lossySource)
        XCTAssertEqual(assess(lossless: false, route: .bluetooth).level, .lossySource)
    }

    func testSpeakerWithMatchedRateIsDirectButNotBitPerfect() {
        XCTAssertEqual(assess(route: .speaker).level, .directLossless)
        XCTAssertEqual(assess(session: 0).level, .unknown)
    }

    func testLosslessSourceDetectionUsesCodecFactsNotJustExtension() {
        func track(_ file: String, depth: Int) -> Track {
            Track(id: UUID(), filename: file, title: "A", artist: "X", album: "Y", duration: 1, sampleRate: 44100, bitDepth: depth)
        }
        XCTAssertTrue(track("a.flac", depth: 24).isLosslessSource)
        XCTAssertTrue(track("a.wav", depth: 16).isLosslessSource)
        XCTAssertTrue(track("a.m4a", depth: 24).isLosslessSource)
        XCTAssertFalse(track("a.m4a", depth: 0).isLosslessSource)
        XCTAssertFalse(track("a.mp3", depth: 0).isLosslessSource)
        XCTAssertFalse(track("a.aac", depth: 0).isLosslessSource)
        // The badge keeps following the same fact after the refactor.
        XCTAssertEqual(track("a.flac", depth: 24).qualityBadge, "Lossless")
        XCTAssertEqual(track("a.mp3", depth: 0).qualityBadge, "MP3")
    }

    func testRouteKindMappingCoversWirelessAndUSBPorts() {
        XCTAssertEqual(AudioRouteKind.from(.bluetoothA2DP), .bluetooth)
        XCTAssertEqual(AudioRouteKind.from(.airPlay), .airPlay)
        XCTAssertEqual(AudioRouteKind.from(.usbAudio), .usb)
        XCTAssertEqual(AudioRouteKind.from(.headphones), .wired)
        XCTAssertEqual(AudioRouteKind.from(.builtInSpeaker), .speaker)
    }
}

final class SearchResultsTests: XCTestCase {
    private func track(_ title: String, artist: String, album: String, file: String) -> Track {
        Track(id: UUID(), filename: file, title: title, artist: artist, album: album, duration: 1, sampleRate: 44100, bitDepth: 16)
    }

    private var library: [Track] {
        [track("Blue Sky", artist: "Ada", album: "Horizons", file: "a.flac"),
         track("Ocean", artist: "Blue Band", album: "Deep", file: "b.flac"),
         track("River", artist: "Cora", album: "Blue Notes", file: "c.flac"),
         track("Mountain", artist: "Ada", album: "Horizons", file: "d.flac")]
    }

    func testSearchGroupsArtistsAlbumsAndRankedSongs() {
        let results = SearchResults.group(tracks: library, query: "blue")
        XCTAssertEqual(results.artists, ["Blue Band"])
        XCTAssertEqual(results.albums.map(\.name), ["Blue Notes", "Deep", "Horizons"])
        // Title match first, then artist match, then album match.
        XCTAssertEqual(results.songs.map(\.title), ["Blue Sky", "Ocean", "River"])
        XCTAssertEqual(results.tracksByArtist["Blue Band"]?.map(\.title), ["Ocean"])
    }

    func testSearchByAlbumNameFindsTheAlbumAndItsSongs() {
        let results = SearchResults.group(tracks: library, query: "Horizons")
        XCTAssertEqual(results.albums.map(\.name), ["Horizons"])
        XCTAssertEqual(Set(results.songs.map(\.title)), ["Blue Sky", "Mountain"])
        XCTAssertTrue(results.artists.isEmpty)
    }

    func testEmptyAndUnknownQueriesReturnNoResults() {
        XCTAssertTrue(SearchResults.group(tracks: library, query: "").isEmpty)
        XCTAssertTrue(SearchResults.group(tracks: library, query: "   ").isEmpty)
        XCTAssertTrue(SearchResults.group(tracks: library, query: "zzzz").isEmpty)
    }
}

final class ArtworkSwipeTests: XCTestCase {
    func testLeftSwipeIsNextAndRightSwipeIsPrevious() {
        XCTAssertEqual(ArtworkSwipe.direction(for: CGSize(width: -120, height: 10)), .next)
        XCTAssertEqual(ArtworkSwipe.direction(for: CGSize(width: 120, height: -10)), .previous)
    }

    func testShortOrVerticalDragsDoNotSkip() {
        XCTAssertNil(ArtworkSwipe.direction(for: CGSize(width: -59, height: 0)))
        XCTAssertNil(ArtworkSwipe.direction(for: CGSize(width: -120, height: 100)))
        XCTAssertNil(ArtworkSwipe.direction(for: CGSize(width: 0, height: 200)))
    }

    func testFollowRequiresHorizontalDominance() {
        XCTAssertTrue(ArtworkSwipe.follows(CGSize(width: -80, height: 40)))
        XCTAssertFalse(ArtworkSwipe.follows(CGSize(width: -80, height: 60)))
        XCTAssertFalse(ArtworkSwipe.follows(CGSize(width: 0, height: 120)))
    }
}

final class ArtworkAnalysisTests: XCTestCase {
    private func solidImage(width: CGFloat, height: CGFloat, color: UIColor = .red) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testDownscaleCapsLongestSideAndKeepsAspect() {
        let image = solidImage(width: 240, height: 120)
        let small = image.downscaled(maxPixel: 96)
        XCTAssertEqual(small.size.width, 96, accuracy: 0.5)
        XCTAssertEqual(small.size.height, 48, accuracy: 0.5)
        XCTAssertTrue(image.downscaled(maxPixel: 300) === image)
    }

    func testAnalysisBuildsPaletteAndTexture() {
        let analysis = ArtworkAnalysis.make(from: solidImage(width: 200, height: 200))
        XCTAssertEqual(analysis.palette.count, 4)
        guard let backdrop = analysis.backdrop else {
            return XCTFail("missing backdrop texture")
        }
        XCTAssertLessThanOrEqual(max(backdrop.size.width, backdrop.size.height), 40.5)
    }

    func testAnalysisCacheRoundTrip() {
        let cache = ArtworkAnalysisCache.shared
        let analysis = ArtworkAnalysis.make(from: solidImage(width: 80, height: 80))
        cache.store(analysis, for: "analysis-test.jpg")
        XCTAssertEqual(cache.analysis(for: "analysis-test.jpg")?.palette.count, 4)
        XCTAssertNil(cache.analysis(for: "analysis-missing.jpg"))
    }
}

final class BrowseAndArtworkPerformanceTests: XCTestCase {
    /// Same groupings `LibraryStore.rebuildDerived` keeps on the snapshot.
    /// Re-reading them must stay cheaper than rebuilding from the view, and
    /// must match the filters the pages used before the cache existed.
    func testDerivedGroupingsMatchFiltersAndAreCheaperToReread() {
        var tracks: [Track] = []
        tracks.reserveCapacity(600)
        for index in 0..<600 {
            var track = Track(
                id: UUID(), filename: "t\(index).flac", title: "Title \(index)",
                artist: index.isMultiple(of: 2) ? "Artist \(index % 40)" : "artist \(index % 40)",
                album: "Album \(index % 25)", duration: 1, sampleRate: 96_000, bitDepth: 24
            )
            track.artists = ["Artist \(index % 40)", "Guest \(index % 7)"]
            track.albumArtist = "Artist \(index % 40)"
            track.favorite = index.isMultiple(of: 5)
            if index.isMultiple(of: 3) { track.lastPlayed = Date(timeIntervalSince1970: Double(index)) }
            tracks.append(track)
        }
        let derived = Self.derive(tracks)
        // Album groups that share a display name tie in `localizedStandardCompare`,
        // and `Dictionary(grouping:)` does not promise an order. Compare identity
        // and the tracks inside each album, which follow library order.
        let directAlbums = AlbumGroup.groups(tracks)
        XCTAssertEqual(Set(derived.albums.map(\.id)), Set(directAlbums.map(\.id)))
        let directTracks = Dictionary(uniqueKeysWithValues: directAlbums.map { ($0.id, $0.tracks.map(\.id)) })
        for album in derived.albums {
            XCTAssertEqual(album.tracks.map(\.id), directTracks[album.id])
        }
        XCTAssertEqual(derived.recent.map(\.id), derived.albums.sorted { $0.latest > $1.latest }.map(\.id))
        let names = Array(Set(tracks.flatMap(\.artistNames))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(derived.names, names)
        for name in names {
            let direct = tracks.filter { $0.artistNames.contains { AudioTags.normalized($0) == AudioTags.normalized(name) } }
            XCTAssertEqual(derived.byArtist[AudioTags.normalized(name)]?.map(\.id), direct.map(\.id))
        }
        XCTAssertEqual(derived.favorites.map(\.id), tracks.filter(\.favorite).map(\.id))
        let recent = tracks.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        XCTAssertEqual(derived.played.map(\.id), recent.map(\.id))

        func elapsed(_ work: () -> Int) -> TimeInterval {
            let start = Date()
            let sink = work()
            XCTAssertGreaterThan(sink, 0)
            return Date().timeIntervalSince(start)
        }
        let direct = elapsed {
            var sink = 0
            for _ in 0..<20 {
                sink += AlbumGroup.groups(tracks).count
                let artists = Array(Set(tracks.flatMap(\.artistNames)))
                sink += artists.count
                for name in artists {
                    sink += tracks.filter { $0.artistNames.contains { AudioTags.normalized($0) == AudioTags.normalized(name) } }.count
                }
            }
            return sink
        }
        let cached = elapsed {
            let built = Self.derive(tracks)
            var sink = built.albums.count + built.names.count
            for _ in 0..<20 {
                sink += built.albums.count + built.recent.count + built.favorites.count
                for name in built.names { sink += built.byArtist[AudioTags.normalized(name)]?.count ?? 0 }
            }
            return sink
        }
        print(String(format: "BROWSE_BENCH direct=%.4fs cachedRefresh=%.4fs ratio=%.1f", direct, cached, direct / max(cached, 0.0001)))
        XCTAssertLessThan(cached, direct)
    }

    private struct DerivedCollections {
        var albums: [AlbumGroup]
        var recent: [AlbumGroup]
        var names: [String]
        var byArtist: [String: [Track]]
        var favorites: [Track]
        var played: [Track]
    }

    /// Mirrors `LibraryStore.rebuildDerived`. Kept here so the cost comparison
    /// does not need to open a store or touch the audio engine.
    private static func derive(_ all: [Track]) -> DerivedCollections {
        let albums = AlbumGroup.groups(all)
        let names = Array(Set(all.flatMap(\.artistNames))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var byArtist: [String: [Track]] = [:]
        for track in all {
            for name in track.artistNames {
                byArtist[AudioTags.normalized(name), default: []].append(track)
            }
        }
        return DerivedCollections(
            albums: albums,
            recent: albums.sorted { $0.latest > $1.latest },
            names: names,
            byArtist: byArtist,
            favorites: all.filter(\.favorite),
            played: all.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        )
    }

    func testArtworkCacheDownsamplesAndReusesTheDecodedBitmap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cover.jpg")
        let source = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }
        try XCTUnwrap(source.jpegData(compressionQuality: 0.85)).write(to: url)
        ArtworkCache.shared.removeAll()
        let small = try XCTUnwrap(ArtworkCache.shared.image(at: url, maxPixel: 64))
        XCTAssertLessThanOrEqual(max(small.size.width, small.size.height), 64.5)
        XCTAssertEqual(small.size.width / small.size.height, 2, accuracy: 0.05)
        let again = try XCTUnwrap(ArtworkCache.shared.image(at: url, maxPixel: 64))
        XCTAssertTrue(small === again)
        let full = try XCTUnwrap(ArtworkCache.shared.image(at: url, maxPixel: 700))
        XCTAssertGreaterThan(max(full.size.width, full.size.height), 64.5)
        XCTAssertLessThanOrEqual(max(full.size.width, full.size.height), 700.5)
        XCTAssertFalse(full === small)
        let smallCost = try XCTUnwrap(small.cgImage).bytesPerRow * small.cgImage!.height
        let fullCost = try XCTUnwrap(full.cgImage).bytesPerRow * full.cgImage!.height
        XCTAssertLessThan(smallCost * 20, fullCost)
        let preview = try XCTUnwrap(ArtworkCache.shared.bestCachedImage(at: url, maxPixel: 64))
        XCTAssertTrue(preview === small)
        let started = Date()
        _ = ArtworkCache.shared.image(at: url, maxPixel: 64)
        let hit = Date().timeIntervalSince(started)
        print(String(format: "ARTWORK_BENCH cacheHit=%.4fs smallBytes=%d fullBytes=%d ratio=%.1f", hit, smallCost, fullCost, Double(fullCost) / Double(max(smallCost, 1))))
    }

    func testArtworkCacheLoadAgreesWithTheSynchronousDecode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cover.jpg")
        let source = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 320)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
        }
        try XCTUnwrap(source.jpegData(compressionQuality: 0.8)).write(to: url)
        ArtworkCache.shared.removeAll()
        // Await outside XCTUnwrap: its autoclosure cannot contain an async call.
        let loadedImage = await ArtworkCache.shared.load(at: url, maxPixel: 80)
        let loaded = try XCTUnwrap(loadedImage)
        XCTAssertLessThanOrEqual(max(loaded.size.width, loaded.size.height), 80.5)
        let cached = try XCTUnwrap(ArtworkCache.shared.cachedImage(at: url, maxPixel: 80))
        XCTAssertTrue(loaded === cached)
    }

    /// The mini player reuses one artwork view across tracks. Once a cover is
    /// cached, the old view used to keep its stored bitmap and skip the new
    /// file. The displayed image must follow the current file instead.
    func testDisplayedArtworkFollowsTheCurrentFileWhenTheNextCoverIsCached() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func jpeg(_ name: String, color: UIColor) throws -> URL {
            let url = root.appendingPathComponent(name)
            let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
            }
            try XCTUnwrap(image.jpegData(compressionQuality: 0.8)).write(to: url)
            return url
        }
        let first = try jpeg("first.jpg", color: .systemRed)
        let second = try jpeg("second.jpg", color: .systemBlue)
        ArtworkCache.shared.removeAll()
        let stale = try XCTUnwrap(ArtworkCache.shared.image(at: first, maxPixel: 240))
        let fresh = try XCTUnwrap(ArtworkCache.shared.image(at: second, maxPixel: 240))
        let tier = ArtworkCache.displayTier(points: 44, scale: 3)
        XCTAssertEqual(tier, 240)
        let firstKey = "\(first.path)#\(Int(tier))"
        let secondKey = "\(second.path)#\(Int(tier))"
        let stuck = FileArtwork.displayedImage(stored: stale, storedKey: firstKey, key: firstKey, url: first, tier: tier)
        XCTAssertTrue(stuck === stale)
        let shown = FileArtwork.displayedImage(stored: stale, storedKey: firstKey, key: secondKey, url: second, tier: tier)
        XCTAssertTrue(shown === fresh)
        XCTAssertFalse(shown === stale)
        // A larger already-decoded tier still stands in until the exact one exists.
        ArtworkCache.shared.removeAll()
        let large = try XCTUnwrap(ArtworkCache.shared.image(at: second, maxPixel: 700))
        let preview = FileArtwork.displayedImage(stored: stale, storedKey: firstKey, key: secondKey, url: second, tier: tier)
        XCTAssertTrue(preview === large)
    }

    func testPullRevealTracksTheFingerAndClearsAtTheDimDistance() {
        XCTAssertEqual(PlayerPull.reveal(for: 0), 1)
        XCTAssertEqual(PlayerPull.reveal(for: -40), 1)
        XCTAssertEqual(PlayerPull.reveal(for: PlayerPull.dimDistance / 2), 0.5, accuracy: 0.001)
        XCTAssertEqual(PlayerPull.reveal(for: PlayerPull.dimDistance), 0)
        XCTAssertEqual(PlayerPull.reveal(for: PlayerPull.dimDistance + 80), 0)
        XCTAssertEqual(PlayerPull.reveal(for: 90), 1 - 90 / PlayerPull.dimDistance, accuracy: 0.001)
    }
}

/// Pure format comparisons and scheduling state only: never starts an audio
/// engine or activates AVAudioSession, including on the CI simulator.
final class GaplessPlaybackTests: XCTestCase {
    private func format(_ rate: Double = 44100, channels: AVAudioChannelCount = 2) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    }

    func testSameProcessingFormatCanPlayGaplessly() {
        XCTAssertTrue(GaplessCompatibility.canJoin(format(), format()))
    }

    func testDifferentSampleRatesCannotPlayGaplessly() {
        XCTAssertFalse(GaplessCompatibility.canJoin(format(), format(48000)))
    }

    func testDifferentChannelCountsCannotPlayGaplessly() {
        XCTAssertFalse(GaplessCompatibility.canJoin(format(), format(channels: 1)))
    }

    func testDifferentPCMFormatsCannotPlayGaplessly() {
        let integer = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100,
                                    channels: 2, interleaved: false)!
        XCTAssertFalse(GaplessCompatibility.canJoin(format(), integer))
    }

    func testPreloadSelectionRespectsQueueEndAndListRepeat() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(GaplessQueueState.nextTrack(in: [a, b], after: a, repeatMode: .off), b)
        XCTAssertNil(GaplessQueueState.nextTrack(in: [a, b], after: b, repeatMode: .off))
        XCTAssertEqual(GaplessQueueState.nextTrack(in: [a, b], after: b, repeatMode: .all), a)
        XCTAssertNil(GaplessQueueState.nextTrack(in: [], after: a, repeatMode: .all))
    }

    func testSingleTrackRepeatNeverPreloads() {
        let a = UUID(), b = UUID()
        XCTAssertNil(GaplessQueueState.nextTrack(in: [a, b], after: a, repeatMode: .one))
        XCTAssertNil(GaplessQueueState.nextTrack(in: [a], after: a, repeatMode: .one))
    }

    func testQueuedTrackAdvancesOnceAndAcceptsFollowingTrack() throws {
        var state = GaplessQueueState()
        let first = state.begin()
        let b = UUID(), c = UUID()
        let second = try XCTUnwrap(state.enqueue(b))
        XCTAssertNil(state.enqueue(c))
        XCTAssertEqual(state.complete(first), .advanced(b))
        XCTAssertNil(state.pending)
        XCTAssertEqual(state.complete(first), .ignored)
        let third = try XCTUnwrap(state.enqueue(c))
        XCTAssertEqual(state.complete(second), .advanced(c))
        XCTAssertEqual(state.complete(third), .finished)
        XCTAssertEqual(state.complete(third), .ignored)
    }

    func testNoPreloadUsesNormalCompletion() {
        var state = GaplessQueueState()
        let first = state.begin()
        XCTAssertEqual(state.complete(first), .finished)
        XCTAssertNil(state.enqueue(UUID()))
    }

    func testSeekInvalidatesPreload() throws { try assertInvalidation(.seek) }
    func testTrackChangeInvalidatesPreload() throws { try assertInvalidation(.trackChange) }
    func testPauseInvalidatesPreload() throws { try assertInvalidation(.pause) }
    func testRepeatChangeInvalidatesPreload() throws { try assertInvalidation(.repeatChange) }
    func testQueueChangeInvalidatesPreload() throws { try assertInvalidation(.queueChange) }
    func testInterruptionInvalidatesPreload() throws { try assertInvalidation(.interruption) }
    func testRouteChangeInvalidatesPreload() throws { try assertInvalidation(.routeChange) }

    func testInvalidationWithoutTailKeepsCurrentCompletion() {
        var state = GaplessQueueState()
        let current = state.begin()
        state.disablePreload()
        XCTAssertNil(state.enqueue(UUID()))
        XCTAssertEqual(state.complete(current), .finished)
    }

    private func assertInvalidation(_ reason: GaplessQueueState.Invalidation,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        var state = GaplessQueueState()
        let oldCurrent = state.begin()
        let oldNext = try XCTUnwrap(state.enqueue(UUID()), file: file, line: line)
        state.invalidate(reason)
        XCTAssertNil(state.pending, file: file, line: line)
        XCTAssertFalse(state.allowsPreload, file: file, line: line)
        XCTAssertEqual(state.complete(oldCurrent), .ignored, file: file, line: line)
        XCTAssertEqual(state.complete(oldNext), .ignored, file: file, line: line)
        // The engine reschedules only the current segment after cancellation.
        let rescheduled = state.begin(allowPreload: false)
        XCTAssertNil(state.enqueue(UUID()), file: file, line: line)
        XCTAssertEqual(state.complete(oldCurrent), .ignored, file: file, line: line)
        XCTAssertEqual(state.complete(oldNext), .ignored, file: file, line: line)
        XCTAssertEqual(state.complete(rescheduled), .finished, file: file, line: line)
        // A subsequent normal load may use gapless again.
        _ = state.begin()
        XCTAssertNotNil(state.enqueue(UUID()), file: file, line: line)
    }
}
