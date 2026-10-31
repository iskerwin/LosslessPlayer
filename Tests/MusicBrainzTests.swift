import XCTest
import UIKit
import CryptoKit
import AVFoundation
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
        var track = localTrack(); track.album = "未知专辑"
        let library = try makeLibrary(track: track, root: root)
        let audio = root.appendingPathComponent(track.filename)
        let bytes = Data("Audio must remain byte-for-byte identical".utf8)
        try bytes.write(to: audio)
        let modified = try audio.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let results = try await client.candidates(for: track)
        XCTAssertEqual(library.tracks.first, track, "Searching never applies even one high-score result")
        XCTAssertEqual(results.count, 1)
        MusicBrainzProtocol.configure { _ in .init(data: Data(#"{"tags":[{"name":" pop "}]}"#.utf8)) }
        var candidate = try await client.candidateForReview(XCTUnwrap(results.first), track: track)
        XCTAssertEqual(library.tracks.first, track, "Review must not save before confirmation")
        candidate.title = "Corrected Song"; candidate.artist = "Ada & Bea"
        candidate.albumArtist = "Various Artists"
        MusicBrainzProtocol.configure { _ in .init(status: 404) }
        let applied = try await library.applyMusicBrainz(candidate, reviewed: track, client: client)
        XCTAssertTrue(applied)
        XCTAssertNil(library.tracks.first?.artworkFilename)
        XCTAssertEqual(library.tracks.first?.album, "Record")
        XCTAssertEqual(library.tracks.first?.genre, "pop")
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
    func testMissingFieldsAreReviewedThenFilledWithoutChangingFavoritesOrPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var track = localTrack()
        track.album = "未知专辑"; track.albumArtist = "  "
        track.favorite = true; track.playCount = 7; track.lastPlayed = Date(timeIntervalSince1970: 1234)
        track.artworkFilename = "existing.artwork"
        let library = try makeLibrary(track: track, root: root)
        library.remember(id: track.id, position: 42)
        library.rememberQueue([track.id], contextOrder: [track.id], shuffle: true)
        let playback = library.playback
        let playbackBytes = try Data(contentsOf: root.appendingPathComponent("playback.json"))
        let catalogBytes = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let results = try await client.candidates(for: track)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.albumScore, 0)
        MusicBrainzProtocol.configure { _ in
            .init(data: Data(#"{"tags":[{"name":"  "},{"name":" (17) "},{"name":"pop"}]}"#.utf8))
        }
        let reviewed = try await client.candidateForReview(XCTUnwrap(results.first), track: track)
        XCTAssertEqual(reviewed.genre, "Rock")
        let requests = MusicBrainzProtocol.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0.url?.path, "/ws/2/release/\(releaseID)")
        let query = URLComponents(url: try XCTUnwrap(requests.first?.0.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertTrue(query?.contains(URLQueryItem(name: "inc", value: "tags")) == true)
        XCTAssertTrue(query?.contains(URLQueryItem(name: "fmt", value: "json")) == true)
        XCTAssertEqual(requests.first?.0.value(forHTTPHeaderField: "User-Agent"), MusicBrainzClient.userAgent)
        // Searching, selecting, then skipping/closing never invokes apply or changes catalog bytes.
        XCTAssertEqual(library.tracks, [track])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), catalogBytes)
        let applied = try await library.applyMusicBrainz(reviewed, reviewed: track, client: client)
        XCTAssertTrue(applied)
        let updated = try XCTUnwrap(library.tracks.first)
        XCTAssertEqual(updated.album, "Record")
        XCTAssertEqual(updated.albumArtist, "Ada")
        XCTAssertEqual(updated.year, 2021)
        XCTAssertEqual(updated.genre, "Rock")
        XCTAssertEqual(updated.favorite, track.favorite)
        XCTAssertEqual(updated.playCount, track.playCount)
        XCTAssertEqual(updated.lastPlayed, track.lastPlayed)
        XCTAssertEqual(library.playback, playback)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("playback.json")), playbackBytes)
        XCTAssertEqual(LibraryStore(root: root).tracks.first, updated)
    }

    func testFillConditionsPreserveExistingValuesIncludingEmptyGenre() async throws {
        let results = try await client.candidates(for: localTrack())
        var candidate = try XCTUnwrap(results.first)
        candidate.album = "Remote Album"; candidate.albumArtist = "Remote Artist"; candidate.genre = "Rock"
        var track = localTrack()
        track.albumArtist = "Local Artist"; track.year = 1998; track.genre = "Local Genre"
        let updated = ReleaseMatching.applying(candidate, to: track)
        XCTAssertEqual(updated.album, "Record")
        XCTAssertEqual(updated.albumArtist, "Local Artist")
        XCTAssertEqual(updated.year, 1998)
        XCTAssertEqual(updated.genre, "Local Genre")
        MusicBrainzProtocol.configure { _ in .init(status: 599) }
        let reviewed = try await client.candidateForReview(candidate, track: track)
        XCTAssertNil(reviewed.genre)
        XCTAssertTrue(MusicBrainzProtocol.requests.isEmpty, "Existing genre must not trigger tag lookup")
        track.genre = ""
        XCTAssertEqual(ReleaseMatching.applying(candidate, to: track).genre, "")
        for album in ["", "未知专辑", "unknown album", " Unknown Album "] {
            track.album = album; track.albumArtist = nil; track.year = nil; track.genre = nil
            let filled = ReleaseMatching.applying(candidate, to: track)
            XCTAssertEqual(filled.album, "Remote Album")
            XCTAssertEqual(filled.albumArtist, "Remote Artist")
            XCTAssertEqual(filled.year, 2021)
            XCTAssertEqual(filled.genre, "Rock")
        }
        candidate.year = nil; candidate.genre = nil; candidate.albumArtist = ""
        let missing = ReleaseMatching.applying(candidate, to: track)
        XCTAssertNil(missing.year)
        XCTAssertNil(missing.genre)
        XCTAssertNil(missing.albumArtist)
    }

    @MainActor
    func testUnavailableTagsStillAllowConfirmationAndNeverInventGenre() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var track = localTrack(); track.album = "unknown album"; track.artworkFilename = "existing.artwork"
        let library = try makeLibrary(track: track, root: root)
        let results = try await client.candidates(for: track)
        let candidate = try XCTUnwrap(results.first)
        for reply in [MusicBrainzProtocol.Reply(status: 400),
                      .init(error: URLError(.notConnectedToInternet)),
                      .init(data: Data("invalid JSON".utf8)),
                      .init(data: Data(#"{"tags":[{"name":" "}]}"#.utf8)),
                      .init(data: Data(#"{}"#.utf8))] {
            MusicBrainzProtocol.configure { _ in reply }
            let reviewed = try await client.candidateForReview(candidate, track: track)
            XCTAssertNil(reviewed.genre)
            XCTAssertEqual(MusicBrainzProtocol.requests.count, 1)
            XCTAssertEqual(library.tracks, [track], "Review alone must not save")
        }
        let reviewed = try await client.candidateForReview(candidate, track: track)
        let applied = try await library.applyMusicBrainz(reviewed, reviewed: track, client: client)
        XCTAssertTrue(applied)
        XCTAssertEqual(library.tracks.first?.album, "Record")
        XCTAssertEqual(library.tracks.first?.year, 2021)
        XCTAssertNil(library.tracks.first?.genre)
    }

    func testTagLookupSharesSearchPacingAndCancellationDoesNotReturnReview() async throws {
        let results = try await client.candidates(for: localTrack())
        let candidate = try XCTUnwrap(results.first)
        let started = try XCTUnwrap(MusicBrainzProtocol.requests.last).1
        MusicBrainzProtocol.configure { _ in .init(data: Data(#"{"tags":[{"name":"pop"}]}"#.utf8)) }
        let reviewed = try await client.candidateForReview(candidate, track: localTrack())
        XCTAssertEqual(reviewed.genre, "pop")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(MusicBrainzProtocol.requests.first).1 - started, 1.0)
        let cancelled = Task {
            try await client.candidateForReview(candidate, track: localTrack())
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled review must not be returned for application")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(MusicBrainzProtocol.requests.count, 1)
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

    // MARK: Background album and cover lookup

    private static let groupID = "44444444-4444-4444-8444-444444444444"
    private static let compilationID = "55555555-5555-4555-8555-555555555555"
    private static let singleID = "66666666-6666-4666-8666-666666666666"

    private func release(_ id: String, _ title: String, date: String, status: String = "Official", type: String = "Album",
                         secondary: [String] = [], group: String? = nil) -> [String: Any] {
        var releaseGroup: [String: Any] = ["primary-type": type, "secondary-types": secondary]
        if let group { releaseGroup["id"] = group }
        return ["id": id, "title": title, "date": date, "status": status, "release-group": releaseGroup,
                "artist-credit": [["artist": ["name": "Ada"], "name": "Ada"]]]
    }

    private func search(_ releases: [[String: Any]], title: String = "Song") -> Data {
        try! JSONSerialization.data(withJSONObject: ["recordings": [
            ["id": recordingID, "title": title, "length": 180000,
             "artist-credit": [["artist": ["name": "Ada"]]], "releases": releases]
        ]])
    }

    private func coverPNG() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
    }

    @MainActor
    private func makeLibrary(tracks: [Track], root: URL) throws -> LibraryStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var snapshot = LibrarySnapshot(); snapshot.tracks = tracks
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("library.json"))
        return LibraryStore(root: root)
    }

    func testAutomaticAlbumPrefersOfficialStudioAlbumAndNeverGuesses() throws {
        struct Results: Decodable { var recordings: [MusicBrainzRecording] }
        func candidates(_ releases: [[String: Any]], album: String = "未知专辑", title: String = "Song") -> [ReleaseCandidate] {
            var track = localTrack(); track.album = album
            let results = try! JSONDecoder().decode(Results.self, from: search(releases, title: title))
            return ReleaseMatching.candidates(for: track, recordings: results.recordings)
        }
        let mixed = [
            release(Self.compilationID, "Hits", date: "1999", secondary: ["Compilation"]),
            release(otherReleaseID, "Bootleg", date: "2000", status: "Bootleg"),
            release(Self.singleID, "Song", date: "2004", type: "Single"),
            release(releaseID, "Record", date: "2005-06-07", group: Self.groupID)
        ]
        let picked = try XCTUnwrap(ReleaseMatching.automaticAlbum(candidates(mixed)))
        XCTAssertEqual(picked.album, "Record")
        XCTAssertEqual(picked.releaseGroupMBID, Self.groupID)
        XCTAssertEqual(ReleaseMatching.automaticAlbum(candidates(Array(mixed.prefix(3))))?.album, "Song",
                       "A single beats a compilation or bootleg")
        XCTAssertNil(ReleaseMatching.automaticAlbum(candidates(Array(mixed.prefix(2)))))
        XCTAssertNil(ReleaseMatching.automaticAlbum(candidates(mixed, title: "Song (Live)")),
                     "Title must match exactly")
        XCTAssertEqual(ReleaseMatching.automaticCover(candidates(mixed, album: "Record"))?.releaseMBID, releaseID)
        XCTAssertNil(ReleaseMatching.automaticCover(candidates(mixed, album: "Other Record")))
    }

    @MainActor
    func testLookupNamesUntaggedSongAndFallsBackToReleaseGroupCover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var track = localTrack(); track.album = "未知专辑"; track.favorite = true
        let library = try makeLibrary(tracks: [track], root: root)
        let png = coverPNG()
        let search = search([release(releaseID, "Record", date: "2005-06-07", group: Self.groupID)])
        MusicBrainzProtocol.configure { request in
            let url = request.url!.absoluteString
            if url.contains("/release-group/") { return .init(data: png) }
            if url.contains("coverartarchive.org") { return .init(status: 404) }
            return .init(data: search)
        }
        await library.lookUpAlbums(client: client)
        let found = try XCTUnwrap(library.tracks.first)
        XCTAssertEqual(found.album, "Record")
        XCTAssertEqual(found.year, 2005)
        XCTAssertEqual(found.title, "Song")
        XCTAssertTrue(found.favorite)
        XCTAssertEqual(found.albumLookedUp, true)
        let name = try XCTUnwrap(found.artworkFilename)
        XCTAssertNotNil(UIImage(contentsOfFile: root.appendingPathComponent(name).path))
        XCTAssertEqual(MusicBrainzProtocol.requests.count, 3)
        XCTAssertEqual(LibraryStore(root: root).tracks.first?.album, "Record")
        await library.lookUpAlbums(client: client)
        XCTAssertEqual(MusicBrainzProtocol.requests.count, 3, "Each song is asked once")
    }

    @MainActor
    func testLookupWithoutConfidentMatchKeepsSongAsItsOwnSingle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var track = localTrack(); track.album = "未知专辑"
        let library = try makeLibrary(tracks: [track], root: root)
        MusicBrainzProtocol.configure { _ in .init(error: URLError(.notConnectedToInternet)) }
        await library.lookUpAlbums(client: client)
        XCTAssertNil(library.tracks.first?.albumLookedUp, "Offline leaves the song for the next launch")
        let search = search([release(Self.compilationID, "Hits", date: "1999", secondary: ["Compilation"])])
        MusicBrainzProtocol.configure { _ in .init(data: search) }
        await library.lookUpAlbums(client: client)
        let kept = try XCTUnwrap(library.tracks.first)
        XCTAssertEqual(kept.albumLookedUp, true)
        XCTAssertEqual(kept.album, "未知专辑")
        XCTAssertEqual(kept.albumTitle, "Song")
        XCTAssertNil(kept.artworkFilename)
        XCTAssertEqual(MusicBrainzProtocol.requests.count, 1, "No cover is fetched for a release that was not chosen")
        XCTAssertEqual(library.albumGroups.map(\.name), ["Song"])
    }

    @MainActor
    func testSwitchedOffLookupSendsNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removeObject(forKey: LibraryStore.albumLookupKey)
        }
        var track = localTrack(); track.album = "未知专辑"
        let library = try makeLibrary(tracks: [track], root: root)
        UserDefaults.standard.set(false, forKey: LibraryStore.albumLookupKey)
        await library.lookUpAlbums(client: client)
        XCTAssertTrue(MusicBrainzProtocol.requests.isEmpty)
        XCTAssertNil(library.tracks.first?.albumLookedUp, "Turning it back on still looks the song up")
        XCTAssertEqual(library.tracks.first?.albumTitle, "Song")
    }

    @MainActor
    func testLookupBorrowsCoverForEveryTrackOfTaggedAlbumWithoutArtwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = localTrack()
        var second = localTrack(); second.id = UUID(); second.title = "Second"; second.filename = "second.flac"
        var covered = localTrack(); covered.id = UUID(); covered.album = "Covered"; covered.filename = "c.flac"
        covered.artworkFilename = "c.artwork"
        let library = try makeLibrary(tracks: [first, second, covered], root: root)
        let png = coverPNG()
        let search = search([release(releaseID, "Record", date: "2005")])
        MusicBrainzProtocol.configure { request in
            request.url!.host == "coverartarchive.org" ? .init(data: png) : .init(data: search)
        }
        await library.lookUpAlbums(client: client)
        XCTAssertEqual(MusicBrainzProtocol.requests.count, 2, "One search and one cover for the whole album")
        let names = library.tracks.prefix(2).map(\.artworkFilename)
        XCTAssertNotNil(names[0])
        XCTAssertEqual(names[0], names[1])
        XCTAssertEqual(library.tracks.map(\.album), ["Record", "Record", "Covered"], "Tagged albums are never renamed")
        XCTAssertNil(library.tracks[2].albumLookedUp, "An album with artwork needs no lookup")
    }

    /// MusicBrainz lists 深夜港湾 under its traditional title 深夜港灣; only a
    /// compilation carries the simplified spelling.
    private func harbourSearch(length: Int = 240000) -> Data {
        func recording(_ id: String, _ title: String, _ releases: [[String: Any]]) -> [String: Any] {
            ["id": id, "title": title, "length": length,
             "artist-credit": [["artist": ["name": "甄楚倩"]]], "releases": releases]
        }
        return try! JSONSerialization.data(withJSONObject: ["recordings": [
            recording(recordingID, "深夜港灣", [release(releaseID, "無伴的舞", date: "1988")]),
            recording("77777777-7777-4777-8777-777777777777", "深夜港湾",
                      [release(Self.compilationID, "靚聲王", date: "2015-05-20", secondary: ["Compilation"])])
        ]])
    }

    private func harbourTrack() -> Track {
        Track(id: UUID(), filename: "深夜港湾-甄楚倩.flac", title: "深夜港湾", artist: "甄楚倩", album: "未知专辑",
              duration: 240, sampleRate: 44100, bitDepth: 16)
    }

    func testAutomaticAlbumMatchesTraditionalTitleForSimplifiedTag() throws {
        struct Results: Decodable { var recordings: [MusicBrainzRecording] }
        let results = try JSONDecoder().decode(Results.self, from: harbourSearch())
        let picked = try XCTUnwrap(ReleaseMatching.automaticAlbum(
            ReleaseMatching.candidates(for: harbourTrack(), recordings: results.recordings)))
        XCTAssertEqual(picked.album, "無伴的舞")
        XCTAssertEqual(picked.year, 1988)
    }

    @MainActor
    func testSongLookedUpUnderOlderRulesIsAskedOnceMore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var track = harbourTrack(); track.albumLookedUp = true
        let library = try makeLibrary(tracks: [track], root: root)
        let search = harbourSearch()
        MusicBrainzProtocol.configure { request in
            request.url!.host == "coverartarchive.org" ? .init(status: 404) : .init(data: search)
        }
        await library.lookUpAlbums(client: client)
        let found = try XCTUnwrap(library.tracks.first)
        XCTAssertEqual(found.album, "無伴的舞")
        XCTAssertEqual(found.albumLookupRules, LibraryStore.albumLookupRules)
        XCTAssertEqual(LibraryStore(root: root).tracks.first?.albumLookupRules, LibraryStore.albumLookupRules)
        let asked = MusicBrainzProtocol.requests.count
        await library.lookUpAlbums(client: client)
        XCTAssertEqual(MusicBrainzProtocol.requests.count, asked, "Asked once under the current rules")
    }

    @MainActor
    func testUnreachableCoverKeepsAlbumAndMovesOnToNextSong() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var other = localTrack(); other.album = "未知专辑"
        let library = try makeLibrary(tracks: [harbourTrack(), other], root: root)
        let harbour = harbourSearch(), song = search([release(releaseID, "Record", date: "2005")])
        MusicBrainzProtocol.configure { request in
            let url = request.url!
            if url.host == "coverartarchive.org" { return .init(error: URLError(.timedOut)) }
            return .init(data: url.absoluteString.contains("Ada") ? song : harbour)
        }
        await library.lookUpAlbums(client: client)
        XCTAssertEqual(library.tracks.map(\.album), ["無伴的舞", "Record"], "Both found despite the covers")
        XCTAssertEqual(library.tracks.map(\.albumLookedUp), [nil, nil], "Covers are tried again next launch")
        XCTAssertEqual(LibraryStore(root: root).tracks.first?.album, "無伴的舞")
        XCTAssertEqual(MusicBrainzProtocol.requests.count, 4, "One search and one cover each, no retries within the pass")
    }

    @MainActor
    func testLookupRunsAgainAfterMigrationRereadsFilenames() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
        buffer.frameLength = 4410
        try AVAudioFile(forWriting: folder.appendingPathComponent("深夜港湾-甄楚倩.wav"), settings: format.settings)
            .write(from: buffer)
        let root = base.appendingPathComponent("Index")
        let scanned = LibraryStore(root: root)
        await scanned.addFolder(folder)
        // The catalog as an older version left it: the whole name as title, no artist.
        var snapshot = scanned.snapshot
        snapshot.tracks[0].catalogVersion = AudioTags.catalogVersion - 1
        snapshot.tracks[0].title = "深夜港湾-甄楚倩"; snapshot.tracks[0].artist = "未知艺术家"
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("library.json"))
        let search = harbourSearch(length: 100)
        MusicBrainzProtocol.configure { request in
            request.url!.host == "coverartarchive.org" ? .init(status: 404) : .init(data: search)
        }
        let library = LibraryStore(root: root)
        // Launch order: the lookup finds nothing to ask before the migration re-reads the file.
        library.startAlbumLookup(client: client)
        await library.albumLookupJob?.value
        XCTAssertTrue(MusicBrainzProtocol.requests.isEmpty)
        library.startCatalogMigration(client: client)
        await library.catalogMigrationJob?.value
        await library.albumLookupJob?.value
        let track = try XCTUnwrap(library.tracks.first)
        XCTAssertEqual(track.artist, "甄楚倩")
        XCTAssertEqual(track.album, "無伴的舞")
    }

    func testUntaggedSongsPresentAsSinglesNamedAfterThemselves() {
        var a = localTrack(); a.album = "未知专辑"; a.folderID = UUID(); a.relativePath = "Mixed/a.flac"
        var b = a; b.id = UUID(); b.title = "Other"; b.relativePath = "Mixed/b.flac"
        XCTAssertEqual(a.albumTitle, "Song")
        XCTAssertNotEqual(a.albumID, b.albumID)
        XCTAssertEqual(AlbumGroup.groups([a, b]).map(\.name), ["Other", "Song"])
        XCTAssertFalse(a.matchesSearch("未知"))
        var tagged = a; tagged.album = "Record"
        XCTAssertEqual(tagged.albumTitle, "Record")
    }
}
