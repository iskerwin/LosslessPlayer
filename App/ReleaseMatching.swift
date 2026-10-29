import Foundation

struct MusicBrainzCredit: Decodable, Sendable {
    struct Artist: Decodable, Sendable { var name: String }
    var name: String?
    var artist: Artist
    var joinphrase: String?

    static func text(_ credits: [Self]?) -> String {
        (credits ?? []).map { ($0.name ?? $0.artist.name) + ($0.joinphrase ?? "") }.joined()
    }
}

struct MusicBrainzRelease: Decodable, Sendable {
    var id: String
    var title: String
    var date: String?
    var country: String?
    var disambiguation: String?
    var artistCredit: [MusicBrainzCredit]?
    enum CodingKeys: String, CodingKey {
        case id, title, date, country, disambiguation
        case artistCredit = "artist-credit"
    }
}

struct MusicBrainzRecording: Decodable, Sendable {
    var id: String
    var title: String
    var length: Double?
    var artistCredit: [MusicBrainzCredit]?
    var releases: [MusicBrainzRelease]?
    enum CodingKeys: String, CodingKey {
        case id, title, length, releases
        case artistCredit = "artist-credit"
    }
}

struct ReleaseCandidate: Identifiable, Equatable, Sendable {
    var recordingMBID: String
    var releaseMBID: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var year: Int?
    var date: String?
    var country: String?
    var disambiguation: String?
    var duration: Double?
    var titleScore: Int
    var artistScore: Int
    var albumScore: Int
    var durationScore: Int
    var score: Int { titleScore + artistScore + albumScore + durationScore }
    var id: String { releaseMBID + "/" + recordingMBID }
}

enum ReleaseMatching {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func known(_ text: String) -> Bool {
        let value = normalized(text)
        return !value.isEmpty && !["未知专辑", "未知艺术家", "unknown album", "unknown artist"].contains(value)
    }

    private static func similarity(_ a: String, _ b: String, weight: Int) -> Int {
        guard known(a), known(b) else { return 0 }
        let a = normalized(a), b = normalized(b)
        if a == b { return weight }
        let left = Set(a.split(separator: " ")), right = Set(b.split(separator: " "))
        return Int(Double(weight) * Double(left.intersection(right).count) / Double(left.union(right).count))
    }

    static func durationScore(local: Double, remote: Double?) -> Int {
        guard local.isFinite, local > 0, let remote, remote.isFinite, remote > 0 else { return 0 }
        let difference = abs(local - remote)
        return difference <= 3 ? 10 : (difference <= 10 ? 5 : 0)
    }

    static func candidates(for track: Track, recordings: [MusicBrainzRecording]) -> [ReleaseCandidate] {
        var unique: [String: ReleaseCandidate] = [:]
        for recording in recordings {
            guard UUID(uuidString: recording.id) != nil else { continue }
            let artist = MusicBrainzCredit.text(recording.artistCredit)
            for release in recording.releases ?? [] {
                guard UUID(uuidString: release.id) != nil else { continue }
                let albumArtist = MusicBrainzCredit.text(release.artistCredit)
                let candidate = ReleaseCandidate(
                    recordingMBID: recording.id, releaseMBID: release.id,
                    title: recording.title, artist: artist, album: release.title,
                    albumArtist: albumArtist.isEmpty ? artist : albumArtist,
                    year: release.date.flatMap { Int($0.prefix(4)) }, date: release.date,
                    country: release.country, disambiguation: release.disambiguation,
                    duration: recording.length.map { $0 / 1000 },
                    titleScore: similarity(track.title, recording.title, weight: 40),
                    artistScore: similarity(track.artist, artist, weight: 30),
                    albumScore: similarity(track.album, release.title, weight: 20),
                    durationScore: durationScore(local: track.duration, remote: recording.length.map { $0 / 1000 }))
                guard candidate.score >= 75, candidate.titleScore >= 24, candidate.artistScore >= 18 else { continue }
                if unique[candidate.id].map({ $0.score < candidate.score }) ?? true { unique[candidate.id] = candidate }
            }
        }
        return unique.values.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
    }

    /// Called only after the user has reviewed and confirmed this candidate.
    static func applying(_ candidate: ReleaseCandidate, to track: Track) -> Track {
        var updated = track
        updated.title = candidate.title
        updated.artist = candidate.artist
        updated.artists = [candidate.artist]
        updated.album = candidate.album
        updated.albumArtist = candidate.albumArtist
        if let year = candidate.year { updated.year = year }
        updated.musicBrainzReleaseMBID = candidate.releaseMBID
        updated.musicBrainzRecordingMBID = candidate.recordingMBID
        return updated
    }
}
