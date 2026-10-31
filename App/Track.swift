import Foundation

struct Track: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var filename: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var sampleRate: Double
    var bitDepth: Int
    var artists: [String]?
    var contentHash: String?
    var musicBrainzReleaseMBID: String?
    var musicBrainzRecordingMBID: String?
    var favorite = false
    // Nil values preserve compatibility with the original copied-file library.
    var folderID: UUID?
    var relativePath: String?
    var fileSize: Int64?
    var modifiedAt: Date?
    var addedAt: Date?
    var artworkFilename: String?
    var trackNumber: Int?
    var discNumber: Int?
    var albumArtist: String?
    var genre: String?
    var year: Int?
    var compilation: Bool?
    var playCount = 0
    var lastPlayed: Date?
    /// Bumped when tag parsing learns new fields, so the next scan re-reads unchanged files once.
    var catalogVersion: Int?
    var missing: Bool?
    var lyrics: String?
    /// Set once the background MusicBrainz album lookup has run for this file, found or not.
    var albumLookedUp: Bool?
    /// `LibraryStore.albumLookupRules` when it was looked up; older marks are asked again.
    var albumLookupRules: Int?
    var available: Bool { missing != true }
    var hasLyrics: Bool {
        let text = lyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !text.isEmpty
    }
    var artistNames: [String] {
        let names = AudioTags.artistNames(from: artists ?? [artist])
        return names.isEmpty ? ["未知艺术家"] : names
    }
    var primaryArtist: String { artistNames.first ?? artist }
    /// Album artist wins. A compilation flag with no album artist groups every track of that album name together.
    var albumArtistName: String {
        let named = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !named.isEmpty { return named }
        if compilation == true { return "合辑" }
        return artist
    }
    var hasAlbum: Bool { ReleaseMatching.known(album) }
    /// What the UI shows as the album. A song with no album tag is presented
    /// as its own single, named after the song, never as "未知专辑".
    var albumTitle: String { hasAlbum ? album : title }
    var albumID: String {
        let title = AudioTags.normalized(album)
        // Each untagged song is its own single, kept apart per folder.
        if !hasAlbum {
            let directory = relativePath.map { ($0 as NSString).deletingLastPathComponent } ?? id.uuidString
            return "unknown\u{1f}" + (folderID?.uuidString ?? "copy") + "\u{1f}" + directory
                + "\u{1f}" + AudioTags.normalized(self.title)
        }
        let named = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if compilation == true, named.isEmpty { return "\u{1f}c\u{1f}" + title }
        return AudioTags.normalized(albumArtistName) + "\u{1f}" + title
    }
    func matchesSearch(_ query: String) -> Bool {
        if query.isEmpty { return true }
        let yearText = year.map(String.init) ?? ""
        let blob = [title, artist, artistNames.joined(separator: " "), albumTitle, albumArtist ?? "", genre ?? "", yearText].joined(separator: " ")
        return blob.localizedCaseInsensitiveContains(query)
    }
    var specification: String {
        let depth = bitDepth > 0 ? "\(bitDepth)-bit · " : ""
        return "\(depth)\(String(format: "%.1f", sampleRate / 1000)) kHz · \((filename as NSString).pathExtension.uppercased())"
    }

    /// Short badge under the Now Playing title. Lossless is a file fact, not a claim of bit-perfect output.
    var qualityBadge: String {
        if isLosslessSource { return "Lossless" }
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext.isEmpty { return "音频" }
        return ext.uppercased()
    }
}

struct MusicFolder: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var bookmark: Data
    var lastScan: Date?
    var scanError: String?
    var excludedPaths: [String] = []
}

struct Playlist: Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var trackIDs: [UUID] = []
    var coverTrackID: UUID?
    var customArtworkFilename: String?
    var sourceFolderID: UUID?
    var sourceDirectory: String?
}

extension Playlist: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, trackIDs, coverTrackID, customArtworkFilename, sourceFolderID, sourceDirectory }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        trackIDs = try container.decodeIfPresent([UUID].self, forKey: .trackIDs) ?? []
        coverTrackID = try container.decodeIfPresent(UUID.self, forKey: .coverTrackID)
        customArtworkFilename = try container.decodeIfPresent(String.self, forKey: .customArtworkFilename)
        sourceFolderID = try container.decodeIfPresent(UUID.self, forKey: .sourceFolderID)
        sourceDirectory = try container.decodeIfPresent(String.self, forKey: .sourceDirectory)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(trackIDs, forKey: .trackIDs)
        try container.encodeIfPresent(coverTrackID, forKey: .coverTrackID)
        try container.encodeIfPresent(customArtworkFilename, forKey: .customArtworkFilename)
        try container.encodeIfPresent(sourceFolderID, forKey: .sourceFolderID)
        try container.encodeIfPresent(sourceDirectory, forKey: .sourceDirectory)
    }
}

struct LibrarySnapshot: Codable {
    /// On-disk format version. Legacy files have no field and decode as 0;
    /// every save writes the current version, so migrations can key off it
    /// instead of guessing from which fields happen to be present.
    static let currentVersion = 1
    var version: Int = LibrarySnapshot.currentVersion
    var tracks: [Track] = []
    var currentID: UUID?
    var position: Double = 0
    var folders: [MusicFolder] = []
    var playlists: [Playlist] = []
    var queueIDs: [UUID] = []
    init() {}
    private enum CodingKeys: CodingKey { case version, tracks, currentID, position, folders, playlists, queueIDs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        currentID = try c.decodeIfPresent(UUID.self, forKey: .currentID)
        position = try c.decodeIfPresent(Double.self, forKey: .position) ?? 0
        folders = try c.decodeIfPresent([MusicFolder].self, forKey: .folders) ?? []
        playlists = try c.decodeIfPresent([Playlist].self, forKey: .playlists) ?? []
        queueIDs = try c.decodeIfPresent([UUID].self, forKey: .queueIDs) ?? []
    }
}

struct PlaybackQueue {
    var ids: [UUID] = []
    var repeatAll = true
    func next(after id: UUID?, backwards: Bool = false) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let id, let index = ids.firstIndex(of: id) else { return ids.first }
        let target = index + (backwards ? -1 : 1)
        if ids.indices.contains(target) { return ids[target] }
        guard repeatAll else { return nil }
        return backwards ? ids.last : ids.first
    }
}

enum RepeatMode: String, Codable, Equatable {
    case off, all, one

    var cycled: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    /// Off and list share `repeat`; single-track repeat uses `repeat.1`.
    var symbolName: String { self == .one ? "repeat.1" : "repeat" }

    var controlTitle: String {
        switch self {
        case .off: return "循环"
        case .all: return "列表"
        case .one: return "单曲"
        }
    }
}

/// Lightweight resume state. Kept out of `library.json` so playback ticks do not rewrite the catalog.
struct PlaybackState: Equatable {
    var currentID: UUID?
    var position: Double = 0
    var queueIDs: [UUID] = []
    var contextOrder: [UUID] = []
    var shuffle = false
    var repeatMode: RepeatMode = .all

    init() {}

    init(currentID: UUID?, position: Double, queueIDs: [UUID], contextOrder: [UUID] = [], shuffle: Bool = false, repeatMode: RepeatMode = .all) {
        self.currentID = currentID
        self.position = position.isFinite ? max(0, position) : 0
        self.queueIDs = queueIDs
        self.contextOrder = contextOrder
        self.shuffle = shuffle
        self.repeatMode = repeatMode
    }
}

extension PlaybackState: Codable {
    private enum CodingKeys: String, CodingKey {
        case currentID, position, queueIDs, contextOrder, shuffle, repeatMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentID = try container.decodeIfPresent(UUID.self, forKey: .currentID)
        let decoded = try container.decodeIfPresent(Double.self, forKey: .position) ?? 0
        position = decoded.isFinite ? max(0, decoded) : 0
        queueIDs = try container.decodeIfPresent([UUID].self, forKey: .queueIDs) ?? []
        contextOrder = try container.decodeIfPresent([UUID].self, forKey: .contextOrder) ?? []
        shuffle = try container.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false
        repeatMode = try container.decodeIfPresent(RepeatMode.self, forKey: .repeatMode) ?? .all
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(currentID, forKey: .currentID)
        try container.encode(position, forKey: .position)
        try container.encode(queueIDs, forKey: .queueIDs)
        try container.encode(contextOrder, forKey: .contextOrder)
        try container.encode(shuffle, forKey: .shuffle)
        try container.encode(repeatMode, forKey: .repeatMode)
    }
}

/// Queue order plus the pre-shuffle context, so turning shuffle off can restore the list the user was playing.
struct QueueOrdering: Equatable {
    var queue: [UUID] = []
    var context: [UUID] = []
    var shuffle = false

    mutating func applyPlay(orderedIDs: [UUID], queue: [UUID], shuffle: Bool) {
        context = orderedIDs
        self.queue = queue
        self.shuffle = shuffle
    }

    mutating func toggleShuffle(current: UUID?) {
        if context.isEmpty { context = queue }
        shuffle.toggle()
        guard let current, queue.contains(current) else { return }
        if shuffle {
            var rest = queue.filter { $0 != current }
            rest.shuffle()
            queue = [current] + rest
        } else {
            queue = Self.restored(context: context, queue: queue)
        }
    }

    static func restored(context: [UUID], queue: [UUID]) -> [UUID] {
        let remaining = Set(queue)
        var result = context.filter { remaining.contains($0) }
        for id in queue where !result.contains(id) { result.append(id) }
        return result
    }

    /// Inserts tracks after the current one, or at the end. The current id is never moved.
    /// Play Next stays immediately after `current` even while the queue is shuffled.
    mutating func insert(_ incoming: [UUID], after current: UUID?, next: Bool) {
        var seen = Set<UUID>()
        let ids = incoming.filter { id in
            if let current, id == current { return false }
            return seen.insert(id).inserted
        }
        guard !ids.isEmpty else { return }
        let drop = Set(ids)
        queue.removeAll { drop.contains($0) }
        context.removeAll { drop.contains($0) }
        if next, let current, let index = queue.firstIndex(of: current) {
            queue.insert(contentsOf: ids, at: index + 1)
            if let contextIndex = context.firstIndex(of: current) {
                context.insert(contentsOf: ids, at: contextIndex + 1)
            } else {
                context.append(contentsOf: ids)
            }
        } else {
            queue.append(contentsOf: ids)
            context.append(contentsOf: ids)
        }
    }
}

enum RemovalNotice {
    static func deletesAppCopy(_ track: Track) -> Bool { track.folderID == nil }

    static func title(for track: Track?) -> String {
        guard let track else { return "移除歌曲？" }
        return deletesAppCopy(track) ? "删除 App 内的副本？" : "从资料库移除歌曲？"
    }

    static func message(for track: Track) -> String {
        if deletesAppCopy(track) {
            return "将删除已经复制到 App 里的副本。你在「文件」中的原始文件不会被改动。"
        }
        return "只移除资料库索引，不会删除文件夹里的原文件。之后重新扫描仍会隐藏这首歌。"
    }

    static func title(for tracks: [Track]) -> String {
        if tracks.count <= 1 { return title(for: tracks.first) }
        return "从资料库中删除 \(tracks.count) 首歌曲？"
    }

    static func message(for tracks: [Track]) -> String {
        if tracks.count <= 1 { return tracks.first.map(message(for:)) ?? "" }
        let copies = tracks.filter(deletesAppCopy).count
        if copies == tracks.count {
            return "将删除已经复制到 App 里的 \(copies) 个副本。你在「文件」中的原始文件不会被改动。"
        }
        if copies == 0 {
            return "只移除这 \(tracks.count) 首的资料库索引，不会删除文件夹里的原文件。"
        }
        return "将移除这 \(tracks.count) 首。其中 \(copies) 首会删除 App 内的副本，其余只移除索引，原文件都会保留。"
    }
}

extension Sequence where Element == Track {
    func firstPlayable() -> Track? { first { $0.available } }
}

/// Whether a visible list is the list playback was started from. Order does not matter; an empty list never matches.
enum PlaybackContext {
    static func matches(list: [UUID], context: [UUID]) -> Bool {
        guard !list.isEmpty, list.count == context.count else { return false }
        return Set(list) == Set(context)
    }
}

/// Now Playing is the only place shuffle and repeat draw their on/off state.
/// The mapping takes the live player flags and no collection snapshot.
struct NowPlayingTransportState: Equatable {
    var playTitle: String
    var playSymbol: String
    var playHighlighted: Bool
    var shuffleHighlighted: Bool
    var repeatTitle: String
    var repeatSymbol: String
    var repeatHighlighted: Bool
    var repeatAccessibility: String
}

enum NowPlayingTransport {
    static func state(playing: Bool, shuffle: Bool, repeatMode: RepeatMode) -> NowPlayingTransportState {
        NowPlayingTransportState(
            playTitle: playing ? "暂停" : "播放",
            playSymbol: playing ? "pause.fill" : "play.fill",
            playHighlighted: playing,
            shuffleHighlighted: shuffle,
            repeatTitle: repeatMode.controlTitle,
            repeatSymbol: repeatMode.symbolName,
            repeatHighlighted: repeatMode != .off,
            repeatAccessibility: repeatMode == .one ? "单曲循环" : repeatMode == .all ? "列表循环" : "循环已关闭"
        )
    }
}
