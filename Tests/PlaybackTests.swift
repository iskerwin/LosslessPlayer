import XCTest
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
