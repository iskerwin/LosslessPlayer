import XCTest
import UIKit
@testable import LosslessPlayer

final class FLACPictureTests: XCTestCase {
    private func integer(_ value: Int, littleEndian: Bool = false) -> Data {
        let shifts = littleEndian ? [0, 8, 16, 24] : [24, 16, 8, 0]
        return Data(shifts.map { UInt8((value >> $0) & 0xff) })
    }

    private func picture(_ type: Int, _ bytes: Data, declaredLength: Int? = nil) -> Data {
        let mime = Data("image/png".utf8)
        let description = Data("封面".utf8)
        var result = integer(type)
        result += integer(mime.count) + mime
        result += integer(description.count) + description
        for value in [16, 16, 24, 0] { result += integer(value) }
        result += integer(declaredLength ?? bytes.count) + bytes
        return result
    }

    private func comments(_ fields: [String]) -> Data {
        var data = integer(0, littleEndian: true) + integer(fields.count, littleEndian: true)
        for field in fields {
            let bytes = Data(field.utf8)
            data += integer(bytes.count, littleEndian: true) + bytes
        }
        return data
    }

    private func flac(_ blocks: [(Int, Data)], audio: Data = Data()) -> Data {
        var data = Data("fLaC".utf8)
        for (index, block) in blocks.enumerated() {
            let length = block.1.count
            data.append(UInt8(block.0 | (index == blocks.count - 1 ? 0x80 : 0)))
            data.append(contentsOf: [UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
            data += block.1
        }
        return data + audio
    }

    private func read(_ data: Data, extension ext: String = "flac") throws -> FLACComments.Metadata {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try FLACComments.readMetadata(url)
        XCTAssertEqual(try Data(contentsOf: url), data, "Metadata reads must never modify the source")
        return result
    }

    func testFrontCoverWinsInEitherOrderAndFirstFrontCoverIsKept() throws {
        let back = Data([1]), front = Data([2]), otherFront = Data([3])
        for blocks in [
            [(6, picture(4, back)), (6, picture(3, front)), (6, picture(3, otherFront))],
            [(6, picture(3, front)), (6, picture(4, back))]
        ] {
            XCTAssertEqual(try read(flac(blocks)).picture, front)
        }
    }

    func testFirstNonFrontCoverIsFallback() throws {
        XCTAssertEqual(try read(flac([(6, picture(4, Data([1]))), (6, picture(0, Data([2])))])).picture, Data([1]))
    }

    func testNoPictureAndNonFLACHaveNoArtwork() throws {
        let data = flac([(4, comments(["TITLE=Song"]))])
        XCTAssertNil(try read(data).picture)
        XCTAssertEqual(try read(data).comments["TITLE"], ["Song"])
        XCTAssertNil(try read(data, extension: "mp3").picture)
        XCTAssertTrue(try read(data, extension: "m4a").comments.isEmpty)
        XCTAssertNil(try read(Data("nope".utf8)).picture)
    }

    func testCommentsSurvivePicturesBeforeAndAfterAndKeepFirstCommentBlock() throws {
        let tags = comments(["artists=Ada", "ARTISTS=Bea", "ALBUM=Record", "TITLE=A=B"])
        for blocks in [
            [(4, tags), (6, picture(3, Data([7]))), (4, comments(["ALBUM=Wrong"]))],
            [(6, picture(3, Data([7]))), (4, tags)]
        ] {
            let result = try read(flac(blocks))
            XCTAssertEqual(result.comments, FLACComments.parse(tags))
            XCTAssertEqual(result.comments["ARTISTS"], ["Ada", "Bea"])
            XCTAssertEqual(result.picture, Data([7]))
        }
    }

    func testAlbumSurvivesCommentFieldOrderLargeBlocksAndLastFlag() throws {
        for fields in [["ALBUM=Record", "TITLE=Song"], ["TITLE=Song", "ALBUM=Record"]] {
            let tags = comments(fields)
            for blocks in [
                [(6, picture(3, Data([7]))), (4, tags)],
                [(4, tags), (6, picture(3, Data([7])))],
                [(1, Data(repeating: 0, count: 5 * 1024 * 1024)), (4, tags)],
                [(4, tags), (4, comments(["ALBUM=Ignored second block"]))]
            ] {
                XCTAssertEqual(try read(flac(blocks)).comments["ALBUM"], ["Record"])
            }
        }
        // A last-block flag terminates metadata; apparent tags in audio are ignored.
        let fakeAudio = flac([(4, comments(["ALBUM=Audio is not metadata"]))])
        XCTAssertNil(try read(flac([(4, comments(["TITLE=Song"]))],
                                  audio: Data(fakeAudio.dropFirst(4)))).comments["ALBUM"])
        // Existing bounded-reader semantics: oversized COMMENT is ignored, not
        // replaced with a later COMMENT; do not change this to guess an album.
        XCTAssertTrue(try read(flac([(4, Data(repeating: 0, count: 4 * 1024 * 1024 + 1)),
                                    (4, comments(["ALBUM=Second"]))])).comments.isEmpty)
    }

    @MainActor
    func testScannerReadsAlbumAndMigratesUnchangedVersionThreeCatalog() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Source")
        let cache = base.appendingPathComponent("Cache")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        // ffmpeg-generated 882-sample mono silence: real STREAMINFO + audio frame.
        let stream = try XCTUnwrap(Data(base64Encoded: "EgASAAAADQAADQrEQPAAAANytSO6L0Q+sIuEhLoiI0mWaA=="))
        let audio = try XCTUnwrap(Data(base64Encoded: "//h5CAADcQ4AAAAB4A=="))
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in
            UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let image = picture(3, try XCTUnwrap(cover.pngData()))
        let layouts = [
            [(0, stream), (4, comments(["ALBUM=Record", "TITLE=Song", "ARTIST=Ada"])), (6, image)],
            [(0, stream), (6, image), (4, comments(["TITLE=Song", "ARTIST=Ada", "ALBUM=Record"]))]
        ]
        for (index, blocks) in layouts.enumerated() {
            try flac(blocks, audio: audio).write(to: source.appendingPathComponent("\(index).flac"))
        }
        for directory in ["Morning", "Evening"] {
            let target = source.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try flac([(0, stream), (4, comments(["TITLE=Song", "ARTIST=Ada"]))], audio: audio)
                .write(to: target.appendingPathComponent("untagged.flac"))
        }
        let folder = MusicFolder(id: UUID(), name: "Source", bookmark: Data())
        let scanner = AudioScanner(root: cache)
        let first = try await scanner.scan(url: source, folder: folder, existing: []) { _, _, _ in }
        XCTAssertTrue(first.failures.isEmpty, "\(first.failures)")
        XCTAssertEqual(first.tracks.count, 4)
        let tagged = first.tracks.filter { $0.album == "Record" }
        XCTAssertEqual(tagged.count, 2)
        XCTAssertTrue(tagged.allSatisfy { $0.artworkFilename != nil })
        let unknown = first.tracks.filter { $0.album == "未知专辑" }
        XCTAssertEqual(unknown.count, 2)
        XCTAssertEqual(Set(unknown.map(\.albumID)).count, 2, "Unknown albums remain folder-scoped")
        var legacy = try XCTUnwrap(tagged.first)
        let originalHash = legacy.contentHash
        legacy.album = "未知专辑"
        legacy.catalogVersion = 3
        legacy.favorite = true
        // File size, modification date and hash are unchanged; version alone
        // must force read(), instead of preserving the stale unknown album.
        let migrated = try await scanner.scan(url: source, folder: folder, existing: [legacy]) { _, _, _ in }
        XCTAssertTrue(migrated.failures.isEmpty, "\(migrated.failures)")
        let updated = try XCTUnwrap(migrated.tracks.first { $0.id == legacy.id })
        XCTAssertEqual(updated.album, "Record")
        XCTAssertEqual(updated.contentHash, originalHash)
        XCTAssertEqual(updated.modifiedAt, legacy.modifiedAt)
        XCTAssertEqual(updated.fileSize, legacy.fileSize)
        XCTAssertTrue(updated.favorite)
        XCTAssertEqual(updated.catalogVersion, AudioTags.catalogVersion)
        XCTAssertGreaterThan(AudioTags.catalogVersion, 3)
        let second = try await scanner.scan(url: source, folder: folder, existing: migrated.tracks) { _, _, _ in }
        XCTAssertEqual(second.skipped, 4)
        XCTAssertEqual(second.tracks.first { $0.id == legacy.id }?.album, "Record")
    }

    private func playableFLAC(_ fields: [String]) throws -> Data {
        let stream = try XCTUnwrap(Data(base64Encoded: "EgASAAAADQAADQrEQPAAAANytSO6L0Q+sIuEhLoiI0mWaA=="))
        let audio = try XCTUnwrap(Data(base64Encoded: "//h5CAADcQ4AAAAB4A=="))
        return flac([(0, stream), (4, comments(fields))], audio: audio)
    }

    func testScannerReadsFLACGenreDateTrackAndDisc() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fields = ["GENRE=Jazz", "DATE=2026-10-30", "TRACKNUMBER=03/12", "DISCNUMBER=2/3"]
        let file = root.appendingPathComponent("song.flac")
        let data = try playableFLAC(fields)
        try data.write(to: file)
        let result = try await AudioScanner(root: root).scan(url: root,
            folder: MusicFolder(id: UUID(), name: "Music", bookmark: Data()), existing: []) { _, _, _ in }
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        let track = try XCTUnwrap(result.tracks.first)
        XCTAssertEqual(track.genre, "Jazz")
        XCTAssertEqual(track.year, 2026)
        XCTAssertEqual(track.trackNumber, 3)
        XCTAssertEqual(track.discNumber, 2)
        XCTAssertEqual(track.catalogVersion, 5)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testScannerSkipsEmptyFirstFLACCommentValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Exercise both album-artist spellings, including an empty preferred key.
        for (index, artistKey) in ["ALBUMARTIST", "ALBUM ARTIST"].enumerated() {
            let fields = ["ALBUM=", "ALBUM=Record", "TITLE=", "TITLE=Song",
                          "ALBUMARTIST=", "\(artistKey)=Ada",
                          "GENRE= \t", "GENRE=Jazz", "GENRE=Rock",
                          "DATE=", "DATE=2026-10-30", "DATE=2000",
                          "TRACKNUMBER=", "TRACKNUMBER=03/12", "TRACKNUMBER=8",
                          "DISCNUMBER=", "DISCNUMBER=2/3", "DISCNUMBER=9"]
            try playableFLAC(fields).write(to: root.appendingPathComponent("\(index).flac"))
        }
        let result = try await AudioScanner(root: root).scan(url: root,
            folder: MusicFolder(id: UUID(), name: "Music", bookmark: Data()), existing: []) { _, _, _ in }
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.tracks.count, 2)
        for track in result.tracks {
            XCTAssertEqual(track.album, "Record")
            XCTAssertEqual(track.title, "Song")
            XCTAssertEqual(track.albumArtist, "Ada")
            XCTAssertEqual(track.genre, "Jazz")
            XCTAssertEqual(track.year, 2026)
            XCTAssertEqual(track.trackNumber, 3)
            XCTAssertEqual(track.discNumber, 2)
        }
    }

    @MainActor
    func testStartupMigratesOnlyStaleFoldersAndLegacyCopiesOnceToVersionFive() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try playableFLAC(["ALBUM=Record", "TITLE=Song", "ARTIST=Ada",
                                    "GENRE=Jazz", "DATE=2026-10-30", "TRACKNUMBER=3/12", "DISCNUMBER=2/3"])
        let library = LibraryStore(root: root)
        for name in ["OldFour", "OldNil", "Current", "Future"] {
            let directory = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("song.flac"))
            await library.addFolder(directory)
        }
        // Seed a legacy copy directly to exercise the original library format.
        try data.write(to: root.appendingPathComponent("legacy.flac"))
        var snapshot = library.snapshot
        var copy = try XCTUnwrap(snapshot.tracks.first)
        copy.id = UUID(); copy.filename = "legacy.flac"; copy.folderID = nil; copy.relativePath = nil
        snapshot.tracks.append(copy)
        let played = Date(timeIntervalSince1970: 123456)
        let added = Date(timeIntervalSince1970: 100000)
        var staleIDs = Set<UUID>()
        for i in snapshot.tracks.indices {
            let name = snapshot.folders.first { $0.id == snapshot.tracks[i].folderID }?.name
            if name == "Current" { snapshot.tracks[i].catalogVersion = 5; continue }
            if name == "Future" { snapshot.tracks[i].catalogVersion = 6; continue }
            staleIDs.insert(snapshot.tracks[i].id)
            snapshot.tracks[i].catalogVersion = name == "OldNil" ? nil : 4
            snapshot.tracks[i].album = "未知专辑"
            snapshot.tracks[i].genre = nil; snapshot.tracks[i].year = nil
            snapshot.tracks[i].trackNumber = nil; snapshot.tracks[i].discNumber = nil
            snapshot.tracks[i].favorite = true; snapshot.tracks[i].playCount = 7
            snapshot.tracks[i].lastPlayed = played; snapshot.tracks[i].addedAt = added
        }
        let lastScans = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0.lastScan) })
        var playlist = Playlist(name: "Keep")
        playlist.trackIDs = snapshot.tracks.map(\.id)
        snapshot.playlists.append(playlist)
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("library.json"))
        let restarted = LibraryStore(root: root)
        await restarted.migrateCatalogIfNeeded()
        XCTAssertFalse(restarted.importing)
        XCTAssertNil(restarted.errorMessage)
        XCTAssertEqual(restarted.tracks.count, 5)
        for track in restarted.tracks where staleIDs.contains(track.id) {
            XCTAssertEqual(track.catalogVersion, 5)
            XCTAssertEqual(track.album, "Record")
            XCTAssertEqual(track.genre, "Jazz")
            XCTAssertEqual(track.year, 2026)
            XCTAssertEqual(track.trackNumber, 3)
            XCTAssertEqual(track.discNumber, 2)
            XCTAssertTrue(track.favorite)
            XCTAssertEqual(track.playCount, 7)
            XCTAssertEqual(track.lastPlayed, played)
            XCTAssertEqual(track.addedAt, added)
        }
        for folder in restarted.snapshot.folders where ["Current", "Future"].contains(folder.name) {
            XCTAssertEqual(folder.lastScan, lastScans[folder.id] ?? nil, "Fresh/future folders must not be scanned")
        }
        XCTAssertEqual(restarted.snapshot.playlists.first?.trackIDs, playlist.trackIDs)
        let migrated = try Data(contentsOf: root.appendingPathComponent("library.json"))
        await restarted.migrateCatalogIfNeeded()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), migrated)
        let nextLaunch = LibraryStore(root: root)
        await nextLaunch.migrateCatalogIfNeeded()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), migrated,
                       "Version five must not trigger another migration")
        for folder in snapshot.folders {
            XCTAssertEqual(try Data(contentsOf: restarted.resolve(folder).appendingPathComponent("song.flac")), data)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("legacy.flac")), data)
    }

    @MainActor
    func testFailedLegacyMigrationRetriesNextLaunchWithoutLooping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var snapshot = LibrarySnapshot()
        let old = Track(id: UUID(), filename: "missing.flac", title: "Old", artist: "未知艺术家",
                        album: "未知专辑", duration: 1, sampleRate: 44100, bitDepth: 16)
        snapshot.tracks = [old]
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("library.json"))
        let library = LibraryStore(root: root)
        await library.migrateCatalogIfNeeded()
        XCTAssertNotNil(library.errorMessage)
        XCTAssertFalse(library.importing)
        XCTAssertNil(library.tracks.first?.catalogVersion)
        let data = try playableFLAC(["ALBUM=Recovered"])
        try data.write(to: root.appendingPathComponent(old.filename))
        await library.migrateCatalogIfNeeded()
        XCTAssertNil(library.tracks.first?.catalogVersion, "No retry loop within a launch")
        let nextLaunch = LibraryStore(root: root)
        await nextLaunch.migrateCatalogIfNeeded()
        XCTAssertEqual(nextLaunch.tracks.first?.id, old.id)
        XCTAssertEqual(nextLaunch.tracks.first?.album, "Recovered")
        XCTAssertEqual(nextLaunch.tracks.first?.catalogVersion, 5)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(old.filename)), data)
    }

    func testTruncatedPictureFieldsAndPayloadAreSkipped() throws {
        let valid = picture(3, Data([1, 2, 3]))
        for length in 0..<valid.count {
            let result = try read(flac([(6, Data(valid.prefix(length))), (4, comments(["TITLE=Still here"]))]))
            XCTAssertNil(result.picture, "prefix length \(length)")
            XCTAssertEqual(result.comments["TITLE"], ["Still here"])
        }
    }

    func testOutOfBoundsLengthsDoNotConsumeNextBlock() throws {
        let invalid = [
            integer(3) + integer(0xffff_ffff),
            integer(3) + integer(0) + integer(0xffff_ffff),
            picture(3, Data([1]), declaredLength: 0xffff_ffff),
            picture(3, Data(), declaredLength: 0)
        ]
        for block in invalid {
            let result = try read(flac([(6, block), (6, picture(4, Data([9])))]))
            XCTAssertEqual(result.picture, Data([9]))
        }
    }

    func testArtworkLimitMatchesAVAssetAndSkipsOversizedFrontCover() throws {
        for length in [FLACComments.artworkByteLimit, FLACComments.artworkByteLimit + 1] {
            let oversized = picture(3, Data(repeating: 0, count: length))
            let result = try read(flac([(6, oversized), (6, picture(4, Data([8])))]))
            XCTAssertEqual(result.picture, Data([8]))
        }
        let allowed = Data(repeating: 1, count: FLACComments.artworkByteLimit - 1)
        XCTAssertEqual(try read(flac([(6, picture(3, allowed))])).picture?.count, allowed.count)
    }

    func testTruncatedOuterBlockAndHeaderPreserveAlreadyReadComments() throws {
        let tags = comments(["ALBUM=Record"])
        let data = flac([(4, tags), (6, picture(3, Data([1, 2, 3])))])
        for removed in [1, 2, 3, picture(3, Data([1, 2, 3])).count + 2] {
            let result = try read(Data(data.dropLast(removed)))
            XCTAssertNil(result.picture)
            XCTAssertEqual(result.comments["ALBUM"], ["Record"])
        }
    }

    func testLastBlockAnd128BlockLimitExcludeAudioPayload() throws {
        let fakeAudio = flac([(6, picture(3, Data([9])))])
        XCTAssertNil(try read(flac([(1, Data())], audio: Data(fakeAudio.dropFirst(4)))).picture)
        let blocks = Array(repeating: (1, Data()), count: 128) + [(6, picture(3, Data([9])))]
        XCTAssertNil(try read(flac(blocks)).picture)
        let withinLimit = Array(repeating: (1, Data()), count: 127) + [(6, picture(3, Data([9])))]
        XCTAssertEqual(try read(flac(withinLimit)).picture, Data([9]))
    }

    @MainActor
    func testRescanUsesFolderBeforeEmbeddedAndPersistsThumbnail() async throws {
        for hasFolderCover in [false, true] {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: base) }
            let source = base.appendingPathComponent("Source")
            let cache = base.appendingPathComponent("Cache")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            func image(_ size: CGSize) throws -> Data {
                let rendered = UIGraphicsImageRenderer(size: size).image { _ in
                    UIColor.red.setFill(); UIRectFill(CGRect(origin: .zero, size: size))
                }
                return try XCTUnwrap(rendered.pngData())
            }
            let file = source.appendingPathComponent("track.flac")
            let data = flac([(6, picture(3, try image(CGSize(width: 16, height: 32))))])
            try data.write(to: file)
            if hasFolderCover {
                try image(CGSize(width: 32, height: 16)).write(to: source.appendingPathComponent("folder.png"))
            }
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            var track = Track(id: UUID(), filename: "track.flac", title: "Song", artist: "Ada", album: "Record",
                              duration: 1, sampleRate: 44100, bitDepth: 16)
            track.relativePath = "track.flac"
            track.fileSize = Int64(try XCTUnwrap(values.fileSize))
            track.modifiedAt = values.contentModificationDate
            track.catalogVersion = AudioTags.catalogVersion
            let folder = MusicFolder(id: UUID(), name: "Source", bookmark: Data())
            let scanner = AudioScanner(root: cache)
            let result = try await scanner.scan(url: source, folder: folder, existing: [track]) { _, _, _ in }
            XCTAssertTrue(result.failures.isEmpty)
            let updated = try XCTUnwrap(result.tracks.first)
            let filename = try XCTUnwrap(updated.artworkFilename)
            let thumbnail = try XCTUnwrap(UIImage(contentsOfFile: cache.appendingPathComponent(filename).path))
            XCTAssertEqual(thumbnail.size.width > thumbnail.size.height, hasFolderCover)
            let restored = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(updated))
            XCTAssertEqual(restored.artworkFilename, filename)
            XCTAssertEqual(try Data(contentsOf: file), data)
            let restarted = AudioScanner(root: cache)
            let second = try await restarted.scan(url: source, folder: folder, existing: [restored]) { _, _, _ in }
            XCTAssertEqual(second.tracks.first?.artworkFilename, filename)
        }
    }
}
