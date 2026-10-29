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
