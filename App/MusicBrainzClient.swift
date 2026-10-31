import Foundation

enum MusicBrainzError: LocalizedError {
    case insufficientMetadata, http(Int), invalidResponse
    var errorDescription: String? {
        switch self {
        case .insufficientMetadata: return "需要已有的标题和艺术家信息才能识别。"
        case .http(let status): return "识别服务暂不可用（HTTP \(status)），请稍后重试。"
        case .invalidResponse: return "识别服务返回了无法读取的数据。"
        }
    }
}

/// Shared across sheets. The explicit gate stays locked across suspension:
/// actor isolation alone would allow concurrent URLSession requests on reentry.
actor MusicBrainzClient {
    static let shared = MusicBrainzClient()
    static let userAgent = "LosslessPlayer/1.0 (https://github.com/iskerwin/LosslessPlayer)"
    private let session: URLSession
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastStart: TimeInterval?

    init(session: URLSession = .shared) { self.session = session }

    static func searchURL(for track: Track) throws -> URL {
        guard ReleaseMatching.known(track.title), ReleaseMatching.known(track.artist) else {
            throw MusicBrainzError.insufficientMetadata
        }
        func quoted(_ text: String) -> String {
            // Escape every Lucene special character, then URLComponents handles transport encoding.
            let special = CharacterSet(charactersIn: "+-!(){}[]^\"~*?:\\/&|")
            return "\"" + text.unicodeScalars.map { special.contains($0) ? "\\" + String($0) : String($0) }.joined() + "\""
        }
        let title = "recording:\(quoted(track.title))"
        var query = "\(title) AND artist:\(quoted(track.artist))"
        if ReleaseMatching.known(track.album) {
            query += " AND (release:\(quoted(track.album))^2 OR \(title))"
        }
        if track.duration.isFinite, track.duration > 0, track.duration < 86_400 {
            let low = Int(max(0, track.duration - 3) * 1000), high = Int((track.duration + 3) * 1000)
            // Optional boost: duration never excludes an otherwise valid recording.
            query += " AND (dur:[\(low) TO \(high)]^2 OR \(title))"
        }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")!
        components.queryItems = [URLQueryItem(name: "query", value: query),
                                 URLQueryItem(name: "fmt", value: "json"), URLQueryItem(name: "limit", value: "25")]
        return components.url!
    }

    func candidates(for track: Track) async throws -> [ReleaseCandidate] {
        struct Results: Decodable { var recordings: [MusicBrainzRecording] }
        let data = try await request(Self.searchURL(for: track))
        let results = try JSONDecoder().decode(Results.self, from: data)
        return ReleaseMatching.candidates(for: track, recordings: results.recordings)
    }

    /// Enrich only the selected candidate before review; lookup failure never blocks metadata confirmation.
    func candidateForReview(_ candidate: ReleaseCandidate, track: Track) async throws -> ReleaseCandidate {
        var reviewed = candidate
        reviewed.genre = nil
        guard track.genre == nil else { return reviewed }
        do {
            guard UUID(uuidString: candidate.releaseMBID) != nil else { throw MusicBrainzError.invalidResponse }
            struct Tag: Decodable { var name: String }
            struct ReleaseTags: Decodable { var tags: [Tag]? }
            let url = URL(string: "https://musicbrainz.org/ws/2/release/\(candidate.releaseMBID)?fmt=json&inc=tags")!
            let data = try await request(url)
            let tags = try JSONDecoder().decode(ReleaseTags.self, from: data)
            reviewed.genre = tags.tags?.lazy.compactMap { AudioTags.genre(from: $0.name) }.first
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw error }
        catch { /* Missing or unavailable tags leave genre nil for the review. */ }
        try Task.checkCancellation()
        return reviewed
    }

    func frontCover(releaseMBID: String) async throws -> Data? {
        guard UUID(uuidString: releaseMBID) != nil else { throw MusicBrainzError.invalidResponse }
        // CAA returns 404 if there is no front image; never synthesize artwork.
        return try await request(URL(string: "https://coverartarchive.org/release/\(releaseMBID)/front-500")!, missingIsEmpty: true)
            .nilIfEmpty
    }

    /// The release's own front cover, else the cover CAA picks for its release
    /// group (another edition of the same album).
    func frontCover(for candidate: ReleaseCandidate) async throws -> Data? {
        if let data = try await frontCover(releaseMBID: candidate.releaseMBID) { return data }
        guard let group = candidate.releaseGroupMBID, UUID(uuidString: group) != nil else { return nil }
        return try await request(URL(string: "https://coverartarchive.org/release-group/\(group)/front-500")!, missingIsEmpty: true)
            .nilIfEmpty
    }

    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }

    /// Apple's album cover when Cover Art Archive has none or cannot be
    /// reached. The Hong Kong storefront: mainland China's lists no music.
    func appleCover(artist: String, album: String) async throws -> Data? {
        guard ReleaseMatching.known(artist), ReleaseMatching.known(album) else { return nil }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [URLQueryItem(name: "term", value: artist + " " + album),
                                 URLQueryItem(name: "entity", value: "album"), URLQueryItem(name: "country", value: "hk"),
                                 URLQueryItem(name: "limit", value: "25")]
        struct Results: Decodable { var results: [AppleAlbum] }
        // Apple allows about 20 searches a minute.
        let data = try await request(components.url!, spacing: 3.1)
        let albums = try JSONDecoder().decode(Results.self, from: data).results
        guard let small = ReleaseMatching.appleAlbum(albums, artist: artist, album: album)?.artworkUrl100,
              let url = URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb")),
              url.scheme == "https" else { return nil }
        return try await request(url, missingIsEmpty: true).nilIfEmpty
    }

    private func request(_ url: URL, missingIsEmpty: Bool = false, spacing: TimeInterval = 1.05) async throws -> Data {
        await acquire()
        defer { release() }
        for attempt in 0...2 {
            try Task.checkCancellation()
            if let lastStart {
                let remaining = spacing - (ProcessInfo.processInfo.systemUptime - lastStart)
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            }
            try Task.checkCancellation()
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(missingIsEmpty ? "image/*" : "application/json", forHTTPHeaderField: "Accept")
            lastStart = ProcessInfo.processInfo.systemUptime
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw MusicBrainzError.invalidResponse }
            if missingIsEmpty && response.statusCode == 404 { return Data() }
            if [429, 503].contains(response.statusCode), attempt < 2 {
                let retry = Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After"))
                let delay = max(pow(2, Double(attempt + 1)), retry)
                guard delay <= 86_400 else { throw MusicBrainzError.http(response.statusCode) }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
            guard (200..<300).contains(response.statusCode) else { throw MusicBrainzError.http(response.statusCode) }
            return data
        }
        throw MusicBrainzError.invalidResponse
    }

    static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval {
        guard let value else { return 0 }
        if let seconds = Double(value), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return max(0, formatter.date(from: value)?.timeIntervalSince(now) ?? 0)
    }
}

private extension Data {
    var nilIfEmpty: Data? { isEmpty ? nil : self }
}
