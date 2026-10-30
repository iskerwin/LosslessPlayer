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
    var status: String?
    var releaseGroup: Group?
    struct Group: Decodable, Sendable {
        var id: String?
        var primaryType: String?
        var secondaryTypes: [String]?
        enum CodingKeys: String, CodingKey {
            case id
            case primaryType = "primary-type"
            case secondaryTypes = "secondary-types"
        }
    }
    enum CodingKeys: String, CodingKey {
        case id, title, date, country, disambiguation, status
        case artistCredit = "artist-credit"
        case releaseGroup = "release-group"
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
    var genre: String? = nil
    var date: String?
    var country: String?
    var disambiguation: String?
    var duration: Double?
    var titleScore: Int
    var artistScore: Int
    var albumScore: Int
    var durationScore: Int
    var status: String? = nil
    var primaryType: String? = nil
    var secondaryTypes: [String] = []
    var releaseGroupMBID: String? = nil
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
                    durationScore: durationScore(local: track.duration, remote: recording.length.map { $0 / 1000 }),
                    status: release.status, primaryType: release.releaseGroup?.primaryType,
                    secondaryTypes: release.releaseGroup?.secondaryTypes ?? [],
                    releaseGroupMBID: release.releaseGroup?.id)
                guard candidate.score >= 75, candidate.titleScore >= 24, candidate.artistScore >= 18 else { continue }
                if unique[candidate.id].map({ $0.score < candidate.score }) ?? true { unique[candidate.id] = candidate }
            }
        }
        return unique.values.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
    }

    /// The release the background lookup may name an untagged song after,
    /// without review: title and artist match exactly, and it is an official
    /// studio album, EP or single (no compilation, live, soundtrack or remix).
    /// Nil leaves the song presented as its own single.
    static func automaticAlbum(_ candidates: [ReleaseCandidate]) -> ReleaseCandidate? {
        preferred(candidates.filter {
            $0.titleScore == 40 && $0.artistScore == 30 && $0.secondaryTypes.isEmpty
                && releaseRank($0) < 3 && known($0.album)
        })
    }

    /// The release whose cover the lookup may borrow for a tagged album with
    /// no artwork: title, artist and album all match exactly.
    static func automaticCover(_ candidates: [ReleaseCandidate]) -> ReleaseCandidate? {
        preferred(candidates.filter { $0.titleScore == 40 && $0.artistScore == 30 && $0.albumScore == 20 })
    }

    /// Official releases only. Albums before EPs before singles before other
    /// types, plain releases before compilations and the like, then the
    /// earliest date (ISO dates sort as text; a missing one goes last).
    private static func preferred(_ candidates: [ReleaseCandidate]) -> ReleaseCandidate? {
        func key(_ c: ReleaseCandidate) -> (Int, Int, String, String) {
            let date = c.date.flatMap { $0.isEmpty ? nil : $0 } ?? "~"
            return (releaseRank(c), c.secondaryTypes.isEmpty ? 0 : 1, date, c.id)
        }
        return candidates.filter { $0.status?.lowercased() == "official" }.min { key($0) < key($1) }
    }

    private static func releaseRank(_ candidate: ReleaseCandidate) -> Int {
        ["album": 0, "ep": 1, "single": 2][candidate.primaryType?.lowercased() ?? ""] ?? 3
    }

    /// Unreviewed, so only blanks are filled: the album and, when missing,
    /// album artist and year. Title and artist stay as tagged.
    static func fillingAlbum(_ candidate: ReleaseCandidate, to track: Track) -> Track {
        var updated = track
        updated.album = candidate.album
        if track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           !candidate.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.albumArtist = candidate.albumArtist
        }
        if track.year == nil { updated.year = candidate.year }
        updated.musicBrainzReleaseMBID = candidate.releaseMBID
        updated.musicBrainzRecordingMBID = candidate.recordingMBID
        return updated
    }

    /// Called only after the user has reviewed and confirmed this candidate.
    static func applying(_ candidate: ReleaseCandidate, to track: Track) -> Track {
        var updated = track
        updated.title = candidate.title
        updated.artist = candidate.artist
        updated.artists = [candidate.artist]
        if !known(track.album) { updated.album = candidate.album }
        if track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           !candidate.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.albumArtist = candidate.albumArtist
        }
        if track.year == nil { updated.year = candidate.year }
        if track.genre == nil { updated.genre = candidate.genre }
        updated.musicBrainzReleaseMBID = candidate.releaseMBID
        updated.musicBrainzRecordingMBID = candidate.recordingMBID
        return updated
    }
}
