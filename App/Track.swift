import Foundation

struct Track: Identifiable, Codable, Equatable {
    var id: UUID
    var filename: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var sampleRate: Double
    var bitDepth: Int
    var favorite = false

    var specification: String {
        let depth = bitDepth > 0 ? "\(bitDepth)-bit · " : ""
        return "\(depth)\(String(format: "%.1f", sampleRate / 1000)) kHz · \((filename as NSString).pathExtension.uppercased())"
    }
}

struct LibrarySnapshot: Codable {
    var tracks: [Track] = []
    var currentID: UUID?
    var position: Double = 0
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
