import XCTest
import AVFoundation
import UIKit
@testable import LosslessPlayer

final class ArtistTagTests: XCTestCase {
    func testArtistAliasesAndMultiArtistBoundaries() {
        XCTAssertEqual(AudioTags.role(for: "vorbis/ARTISTS"), .artists)
        XCTAssertEqual(AudioTags.role(for: "vorbis/ARTIS"), .artist)
        XCTAssertEqual(AudioTags.role(for: "id3/TPE1"), .artist)
        XCTAssertEqual(AudioTags.role(for: "vorbis/ALBUMARTIST"), .albumArtist)
        XCTAssertEqual(AudioTags.artistNames(from: ["Ada; Bea", " ada ", "AC/DC", "Earth, Wind & Fire"]),
                       ["Ada", "Bea", "AC/DC", "Earth, Wind & Fire"])
    }

    func testFormatSpecificAlbumIdentifiersDoNotConsumeAlbumArtist() {
        for key in ["id3/TALB", "itsk/©alb", "vorbis/ALBUM", "riff/IPRD"] {
            XCTAssertEqual(AudioTags.role(for: key), .album, key)
        }
        for key in ["id3/TPE2", "itsk/aART", "vorbis/ALBUMARTIST", "vorbis/ALBUM ARTIST"] {
            XCTAssertEqual(AudioTags.role(for: key), .albumArtist, key)
        }
        XCTAssertNil(AudioTags.role(for: "vorbis/NOT_AN_ALBUM"))
    }

    func testVorbisCommentsPreserveRepeatedArtistsAndRejectTruncation() {
        var data = Data()
        func integer(_ value: Int) { var little = UInt32(value).littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        integer(0)
        integer(3)
        for field in ["ARTISTS=Ada", "ARTISTS=Bea", "ALBUM=Record"] {
            let bytes = Data(field.utf8); integer(bytes.count); data.append(bytes)
        }
        XCTAssertEqual(FLACComments.parse(data)["ARTISTS"], ["Ada", "Bea"])
        XCTAssertTrue(FLACComments.parse(Data(data.dropLast())).isEmpty)
    }

    func testAlbumIdentityNormalizesTagsAndSeparatesUnknownDirectories() throws {
        var a = Track(id: UUID(), filename: "a.wav", title: "A", artist: "Ada", album: " Record ", duration: 1, sampleRate: 44100, bitDepth: 16)
        var b = a; b.id = UUID(); b.album = "record"; b.artist = "ada"
        XCTAssertEqual(a.albumID, b.albumID)
        a.album = "未知专辑"; b.album = "未知专辑"
        a.folderID = UUID(); b.folderID = a.folderID
        a.relativePath = "Morning/a.wav"; b.relativePath = "Evening/b.wav"
        XCTAssertNotEqual(a.albumID, b.albumID)
        a.artists = ["Ada", "Bea"]
        let decoded = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(decoded.artistNames, ["Ada", "Bea"])
    }
}

@MainActor
final class FolderPlaylistTests: XCTestCase {
    private func wav(_ url: URL, sample: Float = 0) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        for i in 0..<128 { buffer.floatChannelData![0][i] = sample }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func testFoldersCreateSeparateStablePlaylistsAndKeepCustomCover() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Music")
        try wav(source.appendingPathComponent("Morning/a.wav"))
        try wav(source.appendingPathComponent("Evening/b.wav"), sample: 0.1)
        let library = LibraryStore(root: base.appendingPathComponent("Library"))
        await library.addFolder(source)
        let folder = try XCTUnwrap(library.snapshot.folders.first)
        library.createPlaylistsFromFolder(folder)
        XCTAssertEqual(Set(library.snapshot.playlists.map(\.name)), ["Morning", "Evening"])
        XCTAssertEqual(library.snapshot.playlists.map(\.trackIDs.count), [1, 1])
        let playlist = try XCTUnwrap(library.snapshot.playlists.first)
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 30)).image { _ in UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 60, height: 30)) }
        XCTAssertTrue(library.setPlaylistArtwork(try XCTUnwrap(picture.jpegData(compressionQuality: 0.8)), for: playlist))
        let cover = try XCTUnwrap(library.snapshot.playlists.first?.customArtworkFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.root.appendingPathComponent(cover).path))
        library.createPlaylistsFromFolder(folder)
        XCTAssertEqual(library.snapshot.playlists.count, 2)
        XCTAssertEqual(library.snapshot.playlists.first?.id, playlist.id)
        let restored = LibraryStore(root: library.root)
        XCTAssertEqual(restored.snapshot.playlists.first?.customArtworkFilename, cover)
        library.resetPlaylistArtwork(playlist)
        XCTAssertNil(library.snapshot.playlists.first?.customArtworkFilename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.root.appendingPathComponent(cover).path))
    }

    func testCopiedImportSkipsIndexedContentAndReportsDuplicates() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Source/a.wav")
        try wav(source)
        let library = LibraryStore(root: base.appendingPathComponent("Library"))
        await library.addFolder(source.deletingLastPathComponent())
        let id = try XCTUnwrap(library.tracks.first?.id)
        await library.importFiles([source])
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertEqual(library.tracks.first?.id, id)
        XCTAssertTrue(library.scanSummary?.contains("重复 1 首") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testUpcomingMoveAndRemovalPreserveCurrentAndHistory() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = LibraryStore(root: base.appendingPathComponent("Library"))
        var sources: [URL] = []
        for index in 0..<4 {
            let file = base.appendingPathComponent("Source/\(index).wav")
            try wav(file, sample: Float(index) / 10)
            sources.append(file)
        }
        await library.importFiles(sources)
        let player = PlayerStore(library: library)
        let tracks = library.tracks
        XCTAssertEqual(tracks.count, 4)
        player.play(tracks, shuffled: false)
        player.load(tracks[1], autoplay: false, keepTransport: true)
        XCTAssertEqual(player.upcomingTracks.map(\.id), Array(tracks.dropFirst(2)).map(\.id))
        player.moveUpcoming(from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(Array(player.queueIDs.prefix(2)), Array(tracks.prefix(2)).map(\.id))
        XCTAssertEqual(player.upcomingTracks.map(\.id), [tracks[3].id, tracks[2].id])
        player.removeUpcoming(at: IndexSet(integer: 0))
        XCTAssertEqual(player.current?.id, tracks[1].id)
        XCTAssertEqual(player.upcomingTracks.map(\.id), [tracks[2].id])
    }
}

@MainActor
final class LibraryIndexAndPersistenceTests: XCTestCase {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func writeWAV(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441))
        buffer.frameLength = 441
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func testIndexResolvesIDsInOrderAndSkipsUnknown() async throws {
        let base = tempRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let library = LibraryStore(root: base.appendingPathComponent("Index"))
        let source = base.appendingPathComponent("song.wav")
        try writeWAV(to: source)
        await library.importFiles([source])
        let track = try XCTUnwrap(library.tracks.first)
        XCTAssertEqual(library.track(track.id)?.id, track.id)
        XCTAssertNil(library.track(nil))
        XCTAssertNil(library.track(UUID()))
        XCTAssertEqual(library.tracks(for: [UUID(), track.id]).map(\.id), [track.id])
        XCTAssertEqual(library.trackByID.count, 1)
        // The index follows mutations: removing the track must not leave a stale entry.
        library.remove(track)
        XCTAssertNil(library.track(track.id))
        XCTAssertTrue(library.trackByID.isEmpty)
    }

    func testDerivedCollectionsFollowLibraryMutations() async throws {
        let base = tempRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let library = LibraryStore(root: base.appendingPathComponent("Derived"))
        let source = base.appendingPathComponent("song.wav")
        try writeWAV(to: source)
        await library.importFiles([source])
        let track = try XCTUnwrap(library.tracks.first)
        let artist = try XCTUnwrap(track.artistNames.first)
        XCTAssertEqual(library.albumGroups.count, 1)
        XCTAssertEqual(library.recentAlbums.map(\.id), library.albumGroups.map(\.id))
        XCTAssertEqual(library.artistNames, track.artistNames)
        XCTAssertEqual(library.tracks(forArtist: artist).map(\.id), [track.id])
        XCTAssertTrue(library.favoriteTracks.isEmpty)
        XCTAssertTrue(library.recentlyPlayed.isEmpty)
        // Mutations flow through persist, which rebuilds the collections:
        // favorite, play history and removal must all show up (and clear).
        library.toggleFavorite(track)
        XCTAssertEqual(library.favoriteTracks.map(\.id), [track.id])
        library.recordPlay(id: track.id)
        XCTAssertEqual(library.recentlyPlayed.map(\.id), [track.id])
        library.remove(track)
        XCTAssertTrue(library.albumGroups.isEmpty)
        XCTAssertTrue(library.artistNames.isEmpty)
        XCTAssertTrue(library.favoriteTracks.isEmpty)
        XCTAssertTrue(library.recentlyPlayed.isEmpty)
    }

    func testAlbumGroupLatestIsNewestAddedDate() {
        var older = Track(id: UUID(), filename: "a.wav", title: "A", artist: "Ada", album: "Record", duration: 1, sampleRate: 44100, bitDepth: 16)
        var newer = Track(id: UUID(), filename: "b.wav", title: "B", artist: "Ada", album: "Record", duration: 1, sampleRate: 44100, bitDepth: 16)
        older.addedAt = Date(timeIntervalSince1970: 10)
        newer.addedAt = Date(timeIntervalSince1970: 99)
        let groups = AlbumGroup.groups([older, newer])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].latest, Date(timeIntervalSince1970: 99))
    }

    func testPersistStampsCurrentVersionAndRotatesBackup() async throws {
        let base = tempRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Index")
        let library = LibraryStore(root: root)
        let source = base.appendingPathComponent("song.wav")
        try writeWAV(to: source)
        await library.importFiles([source])
        XCTAssertEqual(library.tracks.count, 1)
        let mainData = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let decoded = try JSONDecoder().decode(LibrarySnapshot.self, from: mainData)
        XCTAssertEqual(decoded.version, LibrarySnapshot.currentVersion)
        // A second save rotates the previous good main file into the backup.
        _ = library.createPlaylist("Mix")
        let backupData = try Data(contentsOf: root.appendingPathComponent("library.backup.json"))
        let backup = try JSONDecoder().decode(LibrarySnapshot.self, from: backupData)
        XCTAssertEqual(backup.tracks.count, 1)
        XCTAssertTrue(backup.playlists.isEmpty)
    }

    func testCorruptMainRecoversFromBackup() async throws {
        let base = tempRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Index")
        let library = LibraryStore(root: root)
        let source = base.appendingPathComponent("song.wav")
        try writeWAV(to: source)
        await library.importFiles([source])
        _ = library.createPlaylist("Mix") // second save creates the backup
        XCTAssertEqual(library.tracks.count, 1)
        try Data("not json".utf8).write(to: root.appendingPathComponent("library.json"))
        let recovered = LibraryStore(root: root)
        XCTAssertEqual(recovered.tracks.count, 1)
        XCTAssertTrue(recovered.errorMessage?.contains("备份") == true)
        // Recovery rewrites a decodable main file.
        let mainData = try Data(contentsOf: root.appendingPathComponent("library.json"))
        XCTAssertEqual(try JSONDecoder().decode(LibrarySnapshot.self, from: mainData).tracks.count, 1)
    }

    func testLegacySnapshotWithoutVersionDecodesAsZero() throws {
        let legacy = #"{"tracks":[],"folders":[],"playlists":[],"queueIDs":[]}"#
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(snapshot.version, 0)
    }
}
