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
