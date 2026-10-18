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
    var favorite = false
    // Nil values preserve compatibility with the original copied-file library.
    var folderID: UUID?
    var relativePath: String?
    var fileSize: Int64?
    var modifiedAt: Date?
    var addedAt: Date?
    var artworkFilename: String?
    var trackNumber: Int?
    var missing: Bool?
    var lyrics: String?
    var available: Bool { missing != true }
    var albumID: String { artist + "\u{1f}" + album }
    var specification: String {
        let depth = bitDepth > 0 ? "\(bitDepth)-bit · " : ""
        return "\(depth)\(String(format: "%.1f", sampleRate / 1000)) kHz · \((filename as NSString).pathExtension.uppercased())"
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

struct Playlist: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var trackIDs: [UUID] = []
}

struct LibrarySnapshot: Codable {
    var tracks: [Track] = []
    var currentID: UUID?
    var position: Double = 0
    var folders: [MusicFolder] = []
    var playlists: [Playlist] = []
    var queueIDs: [UUID] = []
    init() {}
    private enum CodingKeys: CodingKey { case tracks, currentID, position, folders, playlists, queueIDs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
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
}

extension Sequence where Element == Track {
    func firstPlayable() -> Track? { first { $0.available } }
}
