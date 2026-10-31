import Foundation
import UniformTypeIdentifiers

enum LibrarySort: String, CaseIterable, Identifiable {
    case title, artist, added, played, album
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: return "标题"
        case .artist: return "艺术家"
        case .added: return "添加日期"
        case .played: return "播放次数"
        case .album: return "专辑顺序"
        }
    }

    func sorted(_ tracks: [Track]) -> [Track] {
        switch self {
        case .title:
            return tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            return tracks.sorted {
                let artist = $0.artist.localizedStandardCompare($1.artist)
                if artist != .orderedSame { return artist == .orderedAscending }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .added:
            return tracks.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
        case .played:
            return tracks.sorted {
                if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .album:
            return tracks.sorted(by: Self.albumOrder)
        }
    }

    static func albumOrder(_ a: Track, _ b: Track) -> Bool {
        let discA = a.discNumber ?? 0, discB = b.discNumber ?? 0
        if discA != discB { return discA < discB }
        let trackA = a.trackNumber ?? Int.max, trackB = b.trackNumber ?? Int.max
        if trackA != trackB { return trackA < trackB }
        return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
    }
}

enum AudioTags {
    /// 6: untagged files named 歌名-艺人 take their title and artist from the name.
    static let catalogVersion = 6

    /// A file with neither title nor artist tag, named 歌名-艺人, takes both
    /// from its name, split at the last hyphen.
    static func fillFromFilename(_ track: inout Track, stem: String) {
        guard track.title == stem, !ReleaseMatching.known(track.artist),
              let range = stem.rangeOfCharacter(from: CharacterSet(charactersIn: "-－–—"), options: .backwards)
        else { return }
        let title = stem[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let artist = stem[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !artist.isEmpty else { return }
        track.title = title
        track.artist = artist
    }

    enum Role: Equatable { case track, disc, artist, artists, album, albumArtist, genre, year, compilation }

    static func role(for key: String) -> Role? {
        let value = key.lowercased()
        if value.hasSuffix("trkn") || value.hasSuffix("trck") || value.hasSuffix("tracknumber") || value.contains("track number") { return .track }
        if value.hasSuffix("disk") || value.hasSuffix("tpos") || value.hasSuffix("discnumber") || value.hasSuffix("/disc") || value.contains("disc number") { return .disc }
        if value.hasSuffix("aart") || value.hasSuffix("tpe2") || value.contains("albumartist") || value.contains("album artist") { return .albumArtist }
        let leaf = value.split(separator: "/").last.map(String.init) ?? value
        if ["album", "talb", "©alb", "iprd"].contains(leaf) || value.hasSuffix(":album") { return .album }
        if leaf == "artists" || value.hasSuffix(":artists") { return .artists }
        if ["artist", "artis", "tpe1", "©art"].contains(leaf) || value.hasSuffix(":artis") { return .artist }
        if value.hasSuffix("©gen") || value.hasSuffix("/gen") || value.hasSuffix("tcon") || value.hasSuffix("genre") { return .genre }
        if value.hasSuffix("©day") || value.hasSuffix("tdrc") || value.hasSuffix("tyer") || value.hasSuffix("/date") || value.hasSuffix("year") { return .year }
        if value.hasSuffix("cpil") || value.hasSuffix("tcmp") || value.contains("compilation") { return .compilation }
        return nil
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.lowercased()
    }

    static func artistNames(from values: [String]) -> [String] {
        var seen = Set<String>()
        return values.flatMap { $0.replacingOccurrences(of: " / ", with: ";")
            .components(separatedBy: CharacterSet(charactersIn: ";\0\n")) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(normalized($0)).inserted }
    }

    static func number(from text: String) -> Int? {
        let head = text.split(separator: "/").first.map(String.init) ?? text
        let digits = head.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        guard !digits.isEmpty, let value = Int(digits), value > 0 else { return nil }
        return value
    }

    /// iTunes `trkn` / `disk` atoms store a big-endian UInt16 at byte offset 2.
    static func number(from data: Data) -> Int? {
        if data.count >= 4, data[0] == 0, data[1] == 0 {
            let value = (Int(data[2]) << 8) | Int(data[3])
            if value > 0 { return value }
        }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
            return number(from: text)
        }
        return nil
    }

    static func year(from text: String) -> Int? {
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
                if digits.count == 4, let year = Int(digits), (1000...9999).contains(year) { return year }
            } else if !digits.isEmpty {
                digits = ""
            }
        }
        return nil
    }

    static func genre(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\0", with: "")
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("("), trimmed.hasSuffix(")"), let index = Int(trimmed.dropFirst().dropLast()), id3Genres.indices.contains(index) {
            return id3Genres[index]
        }
        if let index = Int(trimmed), trimmed.allSatisfy(\.isNumber), id3Genres.indices.contains(index) { return id3Genres[index] }
        return trimmed
    }

    static func compilation(from text: String) -> Bool {
        ["1", "true", "yes"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func compilation(from data: Data) -> Bool {
        data.count <= 8 && data.contains(1)
    }

    static let id3Genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk",
        "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
        "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes",
        "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock"
    ]
}

enum FolderArtwork {
    static let preferredNames = ["cover.jpg", "cover.jpeg", "cover.png", "folder.jpg", "folder.jpeg", "folder.png", "front.jpg", "front.png"]

    static func url(in directory: URL, entries: [String]) -> URL? {
        let map = Dictionary(entries.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for name in preferredNames {
            if let original = map[name] { return directory.appendingPathComponent(original) }
        }
        return nil
    }
}

struct M3UEntry: Equatable {
    var path: String
    var title: String?
    var artist: String?
    var duration: Int?
}

enum VisibleSongSelection {
    static func allVisibleSelected(_ visible: [UUID], in selected: Set<UUID>) -> Bool {
        !visible.isEmpty && visible.allSatisfy(selected.contains)
    }

    static func anyVisibleSelected(_ visible: [UUID], in selected: Set<UUID>) -> Bool {
        visible.contains(where: selected.contains)
    }

    static func selectVisible(_ visible: [UUID], in selected: Set<UUID>) -> Set<UUID> {
        selected.union(visible)
    }

    static func deselectVisible(_ visible: [UUID], in selected: Set<UUID>) -> Set<UUID> {
        selected.subtracting(visible)
    }
}

enum PlaylistFileTypes {
    static let m3u = UTType(tag: "m3u", tagClass: .filenameExtension, conformingTo: .plainText) ?? .plainText
    static let m3u8 = UTType(tag: "m3u8", tagClass: .filenameExtension, conformingTo: .plainText) ?? .plainText
    static var readable: [UTType] { [.plainText, m3u, m3u8] }
}

enum PlaylistExchange {
    static func parse(_ text: String) -> [M3UEntry] {
        var entries: [M3UEntry] = []
        var pendingTitle: String?
        var pendingArtist: String?
        var pendingDuration: Int?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.uppercased().hasPrefix("#EXTINF:") {
                let payload = line.dropFirst("#EXTINF:".count)
                let parts = payload.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                pendingDuration = Int(parts.first?.split(separator: " ").first.map(String.init) ?? "")
                pendingArtist = nil
                pendingTitle = nil
                if parts.count > 1 {
                    let rest = parts[1].trimmingCharacters(in: .whitespaces)
                    if let range = rest.range(of: " - ") {
                        pendingArtist = String(rest[..<range.lowerBound])
                        pendingTitle = String(rest[range.upperBound...])
                    } else if !rest.isEmpty {
                        pendingTitle = String(rest)
                    }
                }
                continue
            }
            if line.hasPrefix("#") { continue }
            let path = line.removingPercentEncoding ?? line
            entries.append(M3UEntry(path: path, title: pendingTitle, artist: pendingArtist, duration: pendingDuration))
            pendingTitle = nil
            pendingArtist = nil
            pendingDuration = nil
        }
        return entries
    }

    static func render(_ tracks: [Track]) -> String {
        var lines = ["#EXTM3U"]
        for track in tracks {
            let seconds = Int(track.duration.isFinite ? track.duration.rounded() : 0)
            lines.append("#EXTINF:\(seconds),\(track.artist) - \(track.title)")
            lines.append(track.relativePath ?? track.filename)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func match(_ entry: M3UEntry, in tracks: [Track]) -> Track? {
        let path = entry.path.replacingOccurrences(of: "\\", with: "/")
        let name = URL(fileURLWithPath: path).lastPathComponent
        if let hit = tracks.first(where: { track in
            guard let relative = track.relativePath else { return false }
            return relative == path || path.hasSuffix("/" + relative)
        }) { return hit }
        if let hit = tracks.first(where: { $0.filename == name || $0.relativePath?.split(separator: "/").last.map(String.init) == name }) {
            return hit
        }
        if let title = entry.title, let artist = entry.artist,
           let hit = tracks.first(where: { $0.title == title && $0.artist == artist }) { return hit }
        if let title = entry.title {
            let hits = tracks.filter { $0.title == title }
            if hits.count == 1 { return hits[0] }
        }
        return nil
    }

    static func read(_ url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty { return text }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }
}

extension Track {
    private enum CodingKeys: String, CodingKey {
        case id, filename, title, artist, artists, contentHash, album, duration, sampleRate, bitDepth, favorite
        case folderID, relativePath, fileSize, modifiedAt, addedAt, artworkFilename, trackNumber, missing, lyrics
        case albumArtist, genre, year, discNumber, compilation, playCount, lastPlayed, catalogVersion
        case musicBrainzReleaseMBID, musicBrainzRecordingMBID, albumLookedUp, albumLookupRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        filename = try container.decode(String.self, forKey: .filename)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        artists = try container.decodeIfPresent([String].self, forKey: .artists)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        musicBrainzReleaseMBID = try container.decodeIfPresent(String.self, forKey: .musicBrainzReleaseMBID)
        musicBrainzRecordingMBID = try container.decodeIfPresent(String.self, forKey: .musicBrainzRecordingMBID)
        album = try container.decode(String.self, forKey: .album)
        duration = try container.decode(Double.self, forKey: .duration)
        sampleRate = try container.decode(Double.self, forKey: .sampleRate)
        bitDepth = try container.decode(Int.self, forKey: .bitDepth)
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt)
        artworkFilename = try container.decodeIfPresent(String.self, forKey: .artworkFilename)
        trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        missing = try container.decodeIfPresent(Bool.self, forKey: .missing)
        lyrics = try container.decodeIfPresent(String.self, forKey: .lyrics)
        albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist)
        genre = try container.decodeIfPresent(String.self, forKey: .genre)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        discNumber = try container.decodeIfPresent(Int.self, forKey: .discNumber)
        compilation = try container.decodeIfPresent(Bool.self, forKey: .compilation)
        playCount = try container.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        lastPlayed = try container.decodeIfPresent(Date.self, forKey: .lastPlayed)
        catalogVersion = try container.decodeIfPresent(Int.self, forKey: .catalogVersion)
        albumLookedUp = try container.decodeIfPresent(Bool.self, forKey: .albumLookedUp)
        albumLookupRules = try container.decodeIfPresent(Int.self, forKey: .albumLookupRules)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(filename, forKey: .filename)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encodeIfPresent(artists, forKey: .artists)
        try container.encodeIfPresent(contentHash, forKey: .contentHash)
        try container.encodeIfPresent(musicBrainzReleaseMBID, forKey: .musicBrainzReleaseMBID)
        try container.encodeIfPresent(musicBrainzRecordingMBID, forKey: .musicBrainzRecordingMBID)
        try container.encode(album, forKey: .album)
        try container.encode(duration, forKey: .duration)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(bitDepth, forKey: .bitDepth)
        try container.encode(favorite, forKey: .favorite)
        try container.encodeIfPresent(folderID, forKey: .folderID)
        try container.encodeIfPresent(relativePath, forKey: .relativePath)
        try container.encodeIfPresent(fileSize, forKey: .fileSize)
        try container.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        try container.encodeIfPresent(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(artworkFilename, forKey: .artworkFilename)
        try container.encodeIfPresent(trackNumber, forKey: .trackNumber)
        try container.encodeIfPresent(missing, forKey: .missing)
        try container.encodeIfPresent(lyrics, forKey: .lyrics)
        try container.encodeIfPresent(albumArtist, forKey: .albumArtist)
        try container.encodeIfPresent(genre, forKey: .genre)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(discNumber, forKey: .discNumber)
        try container.encodeIfPresent(compilation, forKey: .compilation)
        try container.encode(playCount, forKey: .playCount)
        try container.encodeIfPresent(lastPlayed, forKey: .lastPlayed)
        try container.encodeIfPresent(catalogVersion, forKey: .catalogVersion)
        try container.encodeIfPresent(albumLookedUp, forKey: .albumLookedUp)
        try container.encodeIfPresent(albumLookupRules, forKey: .albumLookupRules)
    }
}
