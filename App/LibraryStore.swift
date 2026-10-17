import Foundation
import AVFoundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot = LibrarySnapshot()
    @Published var errorMessage: String?
    @Published private(set) var importing = false
    let root: URL
    private var indexURL: URL { root.appendingPathComponent("library.json") }
    var tracks: [Track] { snapshot.tracks }
    static let extensions: Set<String> = ["flac", "m4a", "wav", "aif", "aiff", "caf"]

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: indexURL))
            }
        } catch { errorMessage = "资料库读取失败：\(error.localizedDescription)" }
    }

    func url(for track: Track) -> URL { root.appendingPathComponent(track.filename) }

    @discardableResult
    private func persist(_ candidate: LibrarySnapshot) -> Bool {
        do {
            try JSONEncoder().encode(candidate).write(to: indexURL, options: .atomic)
            snapshot = candidate
            return true
        } catch {
            errorMessage = "资料库保存失败：\(error.localizedDescription)"
            return false
        }
    }

    func remember(id: UUID?, position: Double) {
        var updated = snapshot
        updated.currentID = id
        updated.position = position.isFinite ? max(0, position) : 0
        persist(updated)
    }

    func toggleFavorite(_ track: Track) {
        var updated = snapshot
        guard let index = updated.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        updated.tracks[index].favorite.toggle()
        persist(updated)
    }

    func remove(_ track: Track) {
        // Commit the index before removing our private copy; never delete the user's source.
        var updated = snapshot
        updated.tracks.removeAll { $0.id == track.id }
        if updated.currentID == track.id { updated.currentID = nil; updated.position = 0 }
        if persist(updated) {
            do { try FileManager.default.removeItem(at: url(for: track)) }
            catch { errorMessage = "条目已移除，但文件清理失败：\(error.localizedDescription)" }
        }
    }

    func importFiles(_ urls: [URL]) async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        var failures: [String] = []
        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            var destination: URL?
            do {
                guard Self.extensions.contains(source.pathExtension.lowercased()) else {
                    throw ImportError.unsupported
                }
                let id = UUID()
                let name = "\(id.uuidString).\(source.pathExtension.lowercased())"
                let target = root.appendingPathComponent(name)
                destination = target
                // File providers may need coordination while downloading/copying.
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var copyError: Error?
                coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
                    do { try FileManager.default.copyItem(at: coordinated, to: target) }
                    catch { copyError = error }
                }
                if let coordinationError { throw coordinationError }
                if let copyError { throw copyError }
                let audio = try AVAudioFile(forReading: target)
                let format = audio.fileFormat
                guard format.sampleRate > 0, audio.length > 0 else { throw ImportError.unsupported }
                let asset = AVURLAsset(url: target)
                let metadata = (try? await asset.load(.commonMetadata)) ?? []
                var title = source.deletingPathExtension().lastPathComponent
                var artist = "未知艺术家"
                var album = "未知专辑"
                for item in metadata {
                    guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
                    switch item.commonKey {
                    case .commonKeyTitle: title = value
                    case .commonKeyArtist: artist = value
                    case .commonKeyAlbumName: album = value
                    default: break
                    }
                }
                let depth = (format.settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue ?? 0
                let track = Track(id: id, filename: name, title: title, artist: artist, album: album,
                                  duration: Double(audio.length) / format.sampleRate,
                                  sampleRate: format.sampleRate, bitDepth: depth)
                var updated = snapshot
                updated.tracks.append(track)
                if !persist(updated) { try? FileManager.default.removeItem(at: target) }
            } catch {
                if let destination { try? FileManager.default.removeItem(at: destination) }
                failures.append("\(source.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }
}

private enum ImportError: LocalizedError {
    case unsupported
    var errorDescription: String? { "不支持的格式或无法解码的文件" }
}
