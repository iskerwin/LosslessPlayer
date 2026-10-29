import XCTest
import UIKit
import CryptoKit
@testable import LosslessPlayer

private let recordingID = "11111111-1111-4111-8111-111111111111"
private let releaseID = "22222222-2222-4222-8222-222222222222"
private let otherReleaseID = "33333333-3333-4333-8333-333333333333"

private func localTrack() -> Track {
    Track(id: UUID(), filename: "original.flac", title: "Song", artist: "Ada", album: "Record",
          duration: 180, sampleRate: 44100, bitDepth: 16)
}

private func responseJSON(releases: [String] = [releaseID], title: String = "Song", length: Int = 180000) -> Data {
    let releaseObjects: [[String: Any]] = releases.map {
        ["id": $0, "title": "Record", "date": "2021-02-03", "country": "GB",
         "artist-credit": [["artist": ["name": "Ada"], "name": "Ada"]]]
    }
    return try! JSONSerialization.data(withJSONObject: ["recordings": [
        ["id": recordingID, "title": title, "length": length,
         "artist-credit": [["artist": ["name": "Ada"]]], "releases": releaseObjects]
    ]])
}

/// Every request, including unexpected hosts, is intercepted. No tests use live networking.
private final class MusicBrainzProtocol: URLProtocol {
    struct Reply {
        var status: Int = 200
        var data: Data = Data()
        var headers: [String: String] = [:]
        var error: URLError? = nil
    }
    static let lock = NSLock()
    private static var responder: ((URLRequest) -> Reply)?
    private static var captured: [(URLRequest, TimeInterval)] = []

    static func configure(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        responder = handler; captured = []
    }
    static var requests: [(URLRequest, TimeInterval)] {
        lock.lock(); defer { lock.unlock() }; return captured
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.captured.append((request, ProcessInfo.processInfo.systemUptime))
        let reply = Self.responder?(request) ?? Reply(status: 599)
        Self.lock.unlock()
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MusicBrainzTests: XCTestCase {
    private var session: URLSession!
    private var client: MusicBrainzClient!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MusicBrainzProtocol.self]
        session = URLSession(configuration: configuration)
        client = MusicBrainzClient(session: session)
        MusicBrainzProtocol.configure { _ in .init(data: responseJSON()) }
    }
    override func tearDown() {
        session.invalidateAndCancel(); session = nil; client = nil
        super.tearDown()
    }

    func testQueryEscapesLuceneAndUsesOptionalAlbumAndDurationBoosts() throws {
        var track = localTrack()
        track.title = "A \"Song\" + (Live) \\ Mix"
        track.artist = "Ada & Bea"
        let url = try MusicBrainzClient.searchURL(for: track)
        XCTAssertEqual(url.host, "musicbrainz.org")
        // URL.path normalizes away a trailing slash on Darwin; components retain the request path.
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path, "/ws/2/recording/")
        let values = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(values["fmt"], "json")
        XCTAssertEqual(values["limit"], "25")
        let query = try XCTUnwrap(values["query"])
        XCTAssertTrue(query.contains("\\\"Song\\\" \\+ \\(Live\\) \\\\ Mix"))
        XCTAssertTrue(query.contains("artist:\"Ada \\& Bea\""))
        XCTAssertTrue(query.contains("release:\"Record\"^2 OR recording:"))
        XCTAssertTrue(query.contains("dur:[177000 TO 183000]^2 OR recording:"))
        track.duration = .nan
        XCTAssertFalse(try MusicBrainzClient.searchURL(for: track).absoluteString.contains("dur"))
        track.artist = "未知艺术家"
        XCTAssertThrowsError(try MusicBrainzClient.searchURL(for: track))
    }

    func testScoringStableRankingDuplicatesAndDurationTolerance() async throws {
        MusicBrainzProtocol.configure { _ in .init(data: responseJSON(releases: [otherReleaseID, releaseID, releaseID])) }
        let results = try await client.candidates(for: localTrack())
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.map(\.releaseMBID), [releaseID, otherReleaseID])
        XCTAssertEqual(results.map(\.score), [100, 100])
        XCTAssertEqual(results.first?.year, 2021)
        XCTAssertEqual(results.first?.albumArtist, "Ada")
        XCTAssertEqual(ReleaseMatching.durationScore(local: 180, remote: 183), 10)
        XCTAssertEqual(ReleaseMatching.durationScore(local: 180, remote: 176.9), 5)
        XCTAssertEqual(ReleaseMatching.durationScore(local: 180, remote: 220), 0)
        XCTAssertEqual(ReleaseMatching.durationScore(local: .nan, remote: 180), 0)
        XCTAssertEqual(ReleaseMatching.durationScore(local: 180, remote: nil), 0)
        MusicBrainzProtocol.configure { _ in .init(data: responseJSON(length: 240000)) }
        let longResults = try await client.candidates(for: localTrack())
        XCTAssertEqual(longResults.first?.score, 90, "Length is a score, never a hard filter")
    }

    func testZeroCandidatesAndWeakMatchesLeaveLibraryAlone() async throws {
        MusicBrainzProtocol.configure { _ in .init(data: responseJSON(releases: [])) }
        let empty = try await client.candidates(for: localTrack())
        XCTAssertTrue(empty.isEmpty)
        MusicBrainzProtocol.configure { _ in .init(data: responseJSON(title: "Unrelated")) }
        let weak = try await client.candidates(for: localTrack())
        XCTAssertTrue(weak.isEmpty)
    }

    func testConcurrentRequestsAreSpacedAndCarryPublicUserAgent() async throws {
        async let first = client.candidates(for: localTrack())
        async let second = client.candidates(for: localTrack())
        async let third = client.candidates(for: localTrack())
        _ = try await (first, second, third)
        let requests = MusicBrainzProtocol.requests
        XCTAssertEqual(requests.count, 3)
        for index in 1..<requests.count {
            XCTAssertGreaterThanOrEqual(requests[index].1 - requests[index - 1].1, 1.0)
        }
        XCTAssertEqual(requests.first?.0.value(forHTTPHeaderField: "User-Agent"), MusicBrainzClient.userAgent)
    }

    func test429And503RetryWithBackoff() async throws {
        var count = 0 // Responder invoked under the protocol lock.
        MusicBrainzProtocol.configure { _ in
            count += 1
            return count <= 2 ? .init(status: count == 1 ? 429 : 503, headers: ["Retry-After": "1"]) : .init(data: responseJSON())
        }
        let results = try await client.candidates(for: localTrack())
        XCTAssertEqual(results.count, 1)
        let requests = MusicBrainzProtocol.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertGreaterThanOrEqual(requests[1].1 - requests[0].1, 2)
        XCTAssertGreaterThanOrEqual(requests[2].1 - requests[1].1, 4)
    }

    func testRetryAfterHTTPDateAndMissingCover() async throws {
        XCTAssertEqual(MusicBrainzClient.retryDelay("10"), 10)
        XCTAssertEqual(MusicBrainzClient.retryDelay("Thu, 01 Jan 1970 00:00:20 GMT", now: Date(timeIntervalSince1970: 10)), 10)
        XCTAssertEqual(MusicBrainzClient.retryDelay("invalid"), 0)
        MusicBrainzProtocol.configure { _ in .init(status: 404) }
        let cover = try await client.frontCover(releaseMBID: releaseID)
        XCTAssertNil(cover)
        XCTAssertEqual(MusicBrainzProtocol.requests.first?.0.url?.host, "coverartarchive.org")
        XCTAssertEqual(MusicBrainzProtocol.requests.first?.0.url?.lastPathComponent, "front-500")
    }

    func testOfflineFailsOnlyTheExplicitRequest() async throws {
        MusicBrainzProtocol.configure { _ in .init(error: URLError(.notConnectedToInternet)) }
        do {
            _ = try await client.candidates(for: localTrack())
            XCTFail("Expected offline error")
        } catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        XCTAssertEqual(MusicBrainzProtocol.requests.count, 1)
    }

    func testPermanentHTTPAndMalformedJSONAreReported() async throws {
        MusicBrainzProtocol.configure { _ in .init(status: 400) }
        do {
            _ = try await client.candidates(for: localTrack())
            XCTFail("Expected HTTP failure")
        } catch { XCTAssertTrue(error is MusicBrainzError) }
        XCTAssertEqual(MusicBrainzProtocol.requests.count, 1)
        MusicBrainzProtocol.configure { _ in .init(data: Data("invalid JSON".utf8)) }
        do {
            _ = try await client.candidates(for: localTrack())
            XCTFail("Expected decoding failure")
        } catch { XCTAssertTrue(error is DecodingError) }
    }

    func testMBIDRoundTripAndLegacyMissingFields() throws {
        var track = localTrack()
        track.musicBrainzReleaseMBID = releaseID
        track.musicBrainzRecordingMBID = recordingID
        XCTAssertEqual(try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track)), track)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(track)) as? [String: Any])
        legacy.removeValue(forKey: "musicBrainzReleaseMBID")
        legacy.removeValue(forKey: "musicBrainzRecordingMBID")
        let decoded = try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.musicBrainzReleaseMBID)
        XCTAssertNil(decoded.musicBrainzRecordingMBID)
    }

    @MainActor
    private func makeLibrary(track: Track, root: URL) throws -> LibraryStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var snapshot = LibrarySnapshot(); snapshot.tracks = [track]
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("library.json"))
        return LibraryStore(root: root)
    }

    @MainActor
    func testConfirmedMetadataAndMissingCoverNeverWriteAudioBytesOrModificationDate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = localTrack()
        let library = try makeLibrary(track: track, root: root)
        let audio = root.appendingPathComponent(track.filename)
        let bytes = Data("Audio must remain byte-for-byte identical".utf8)
        try bytes.write(to: audio)
        let modified = try audio.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let results = try await client.candidates(for: track)
        XCTAssertEqual(library.tracks.first, track, "Searching never applies even one high-score result")
        var candidate = try XCTUnwrap(results.first)
        candidate.title = "Corrected Song"; candidate.artist = "Ada & Bea"
        candidate.albumArtist = "Various Artists"
        MusicBrainzProtocol.configure { _ in .init(status: 404) }
        let applied = try await library.applyMusicBrainz(candidate, reviewed: track, client: client)
        XCTAssertTrue(applied)
        XCTAssertNil(library.tracks.first?.artworkFilename)
        XCTAssertEqual(library.tracks.first?.title, "Corrected Song")
        XCTAssertEqual(library.tracks.first?.artistNames, ["Ada & Bea"])
        XCTAssertEqual(library.tracks.first?.albumArtist, "Various Artists")
        XCTAssertEqual(library.tracks.first?.musicBrainzReleaseMBID, releaseID)
        XCTAssertEqual(LibraryStore(root: root).tracks.first?.musicBrainzRecordingMBID, recordingID)
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: audio)), SHA256.hash(data: bytes))
        XCTAssertEqual(try audio.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        XCTAssertEqual(library.url(for: track), audio)
    }

    @MainActor
    func testMultipleCandidatesRequireChoiceAndInvalidArtworkIsNotStored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = localTrack()
        let library = try makeLibrary(track: track, root: root)
        MusicBrainzProtocol.configure { _ in .init(data: responseJSON(releases: [releaseID, otherReleaseID])) }
        let candidates = try await client.candidates(for: track)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(library.tracks, [track])
        XCTAssertNil(library.tracks.first?.musicBrainzReleaseMBID)
        MusicBrainzProtocol.configure { _ in .init(data: Data("not an image".utf8)) }
        let applied = try await library.applyMusicBrainz(candidates[1], reviewed: track, client: client)
        XCTAssertTrue(applied)
        XCTAssertEqual(library.tracks.first?.musicBrainzReleaseMBID, otherReleaseID)
        XCTAssertNil(library.tracks.first?.artworkFilename)
        XCTAssertNotNil(library.musicBrainzNotice)
    }

    @MainActor
    func testExistingArtworkIsPreservedWithoutCoverRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var track = localTrack(); track.artworkFilename = "embedded.artwork"
        let library = try makeLibrary(track: track, root: root)
        let original = Data("original cover".utf8)
        try original.write(to: root.appendingPathComponent(track.artworkFilename!))
        let candidates = try await client.candidates(for: track)
        let candidate = try XCTUnwrap(candidates.first)
        MusicBrainzProtocol.configure { _ in .init(status: 599) }
        let applied = try await library.applyMusicBrainz(candidate, reviewed: track, client: client)
        XCTAssertTrue(applied)
        XCTAssertTrue(MusicBrainzProtocol.requests.isEmpty)
        XCTAssertEqual(library.tracks.first?.artworkFilename, track.artworkFilename)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(track.artworkFilename!)), original)
    }

    @MainActor
    func testDownloadedCoverUsesScannerThumbnailAndStaleReviewCannotOverwriteEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = localTrack()
        let library = try makeLibrary(track: track, root: root)
        let candidates = try await client.candidates(for: track)
        let candidate = try XCTUnwrap(candidates.first)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 900))
        let png = renderer.pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 900))
        }
        MusicBrainzProtocol.configure { _ in .init(data: png) }
        let applied = try await library.applyMusicBrainz(candidate, reviewed: track, client: client)
        XCTAssertTrue(applied)
        let name = try XCTUnwrap(library.tracks.first?.artworkFilename)
        XCTAssertTrue(name.hasSuffix(".artwork"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: root.appendingPathComponent(name).path))
        XCTAssertLessThanOrEqual(image.size.width, 700)
        XCTAssertLessThanOrEqual(image.size.height, 700)
        XCTAssertNotNil(ArtworkCache.shared.image(at: root.appendingPathComponent(name)))
        library.toggleFavorite(library.tracks[0])
        do {
            _ = try await library.applyMusicBrainz(candidate, reviewed: track, client: client)
            XCTFail("A stale review must fail")
        } catch { XCTAssertTrue(error is MusicBrainzApplyError) }
        XCTAssertTrue(library.tracks[0].favorite)
    }
}
