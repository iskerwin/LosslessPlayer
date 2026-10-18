import XCTest
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
}
