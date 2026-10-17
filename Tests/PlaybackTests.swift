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
