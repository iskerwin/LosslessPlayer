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
        library.remember(id: track.id, position: 0.05)
        let restored = LibraryStore(root: root)
        XCTAssertEqual(restored.tracks.first?.favorite, true)
        XCTAssertEqual(restored.snapshot.currentID, track.id)
        XCTAssertEqual(restored.snapshot.position, 0.05)
        restored.remove(track)
        XCTAssertTrue(restored.tracks.isEmpty)
        XCTAssertNil(restored.snapshot.currentID)
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
        let id = try XCTUnwrap(library.snapshot.folders.first?.id)
        library.remove(track)
        await library.scanFolder(id)
        XCTAssertTrue(library.tracks.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
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
