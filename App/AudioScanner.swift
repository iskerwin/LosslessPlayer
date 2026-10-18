import Foundation
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct ScanResult: Sendable {
    var tracks: [Track] = []
    var seen: Set<String> = []
    var failures: [String] = []
    var skipped = 0
}

/// File-provider reads and audio parsing are isolated from the UI actor.
actor AudioScanner {
    static let extensions: Set<String> = ["flac", "m4a", "wav", "aif", "aiff", "caf", "mp3", "aac"]
    let root: URL
    init(root: URL) { self.root = root }

    func scan(url: URL, folder: MusicFolder, existing: [Track],
              progress: @escaping @Sendable (Int, Int, String) async -> Void) async throws -> ScanResult {
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        var candidates: [URL] = []
        var scanRoot = url
        var enumerationError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { directory in
            scanRoot = directory
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                    enumerationError = error; return false
                }) else { enumerationError = CocoaError(.fileReadUnknown); return }
            for case let file as URL in enumerator {
                if Task.isCancelled { enumerationError = CancellationError(); break }
                do {
                    let values = try file.resourceValues(forKeys: Set(keys))
                    if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    if values.isRegularFile == true && Self.extensions.contains(file.pathExtension.lowercased()) {
                        candidates.append(file)
                    }
                } catch { enumerationError = error; break }
            }
        }
        if let coordinationError { throw coordinationError }
        if let enumerationError { throw enumerationError }
        let old = Dictionary(existing.compactMap { track -> (String, Track)? in
            guard let path = track.relativePath else { return nil }; return (path, track)
        }, uniquingKeysWith: { first, _ in first })
        var result = ScanResult()
        var lookedArt = Set<String>()
        var foundArt: [String: URL] = [:]
        func artwork(beside file: URL) -> URL? {
            let directory = file.deletingLastPathComponent()
            let key = Self.canonicalPath(directory)
            if lookedArt.contains(key) { return foundArt[key] }
            lookedArt.insert(key)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            if let match = FolderArtwork.url(in: directory, entries: entries) {
                foundArt[key] = match
                return match
            }
            return nil
        }
        for (index, file) in candidates.sorted(by: { $0.path < $1.path }).enumerated() {
            try Task.checkCancellation()
            guard let relative = Self.relativePath(for: file, in: scanRoot) else {
                result.failures.append("\(file.lastPathComponent)：无法定位相对路径")
                continue
            }
            result.seen.insert(relative)
            await progress(index + 1, candidates.count, file.lastPathComponent)
            if folder.excludedPaths.contains(relative) { result.skipped += 1; continue }
            do {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                if var track = old[relative], track.fileSize == Int64(values.fileSize ?? -1),
                   track.modifiedAt == values.contentModificationDate, track.catalogVersion == AudioTags.catalogVersion {
                    track.missing = false; track.lyrics = sidecarLyrics(file)
                    if track.artworkFilename == nil, let image = artwork(beside: file) {
                        track.artworkFilename = storeThumbnail(at: image, id: track.id)
                    }
                    result.tracks.append(track); result.skipped += 1; continue
                }
                var track = try await read(file, id: old[relative]?.id ?? UUID())
                if track.artworkFilename == nil, let image = artwork(beside: file) {
                    track.artworkFilename = storeThumbnail(at: image, id: track.id)
                }
                track.folderID = folder.id; track.relativePath = relative
                track.filename = file.lastPathComponent
                track.favorite = old[relative]?.favorite ?? false
                track.addedAt = old[relative]?.addedAt ?? Date()
                result.tracks.append(track)
            } catch is CancellationError { throw CancellationError() }
            catch { result.failures.append("\(file.lastPathComponent)：\(error.localizedDescription)") }
        }
        return result
    }

    func importCopy(_ url: URL) async throws -> Track {
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        guard Self.extensions.contains(url.pathExtension.lowercased()) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let file = root.appendingPathComponent(UUID().uuidString + "." + url.pathExtension.lowercased())
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: file) } }
        try coordinateCopy(from: url, to: file)
        try Task.checkCancellation()
        // Content-address copies to prevent duplicates even when filenames differ.
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation(); hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let target = root.appendingPathComponent(digest + "." + url.pathExtension.lowercased())
        var track = try await read(file, id: UUID())
        if track.artworkFilename == nil {
            let directory = url.deletingLastPathComponent()
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            if let image = FolderArtwork.url(in: directory, entries: entries) {
                track.artworkFilename = storeThumbnail(at: image, id: track.id)
            }
        }
        track.lyrics = sidecarLyrics(url)
        track.title = track.title == file.deletingPathExtension().lastPathComponent ? url.deletingPathExtension().lastPathComponent : track.title
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: file) }
        else { try FileManager.default.moveItem(at: file, to: target) }
        track.filename = target.lastPathComponent
        finished = true
        return track
    }

    private func coordinateCopy(from source: URL, to target: URL) throws {
        var coordinationError: NSError?, copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { file in
            do { try FileManager.default.copyItem(at: file, to: target) } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }; if let copyError { throw copyError }
    }

    private func read(_ url: URL, id: UUID) async throws -> Track {
        var audio: AVAudioFile?
        var readError: Error?, coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { file in
            do { audio = try AVAudioFile(forReading: file) } catch { readError = error }
        }
        if let coordinationError { throw coordinationError }; if let readError { throw readError }
        guard let audio, audio.length > 0, audio.fileFormat.sampleRate > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let format = audio.fileFormat
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var track = Track(id: id, filename: url.lastPathComponent,
            title: url.deletingPathExtension().lastPathComponent, artist: "未知艺术家", album: "未知专辑",
            duration: Double(audio.length) / format.sampleRate, sampleRate: format.sampleRate,
            bitDepth: (format.settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue ?? 0)
        track.fileSize = Int64(values.fileSize ?? 0); track.modifiedAt = values.contentModificationDate
        track.addedAt = Date(); track.missing = false
        let metadata = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
        for item in metadata {
            try Task.checkCancellation()
            if item.commonKey == .commonKeyArtwork, let data = try? await item.load(.dataValue), data.count < 12_000_000,
               let source = CGImageSourceCreateWithData(data as CFData, nil) {
                track.artworkFilename = storeThumbnail(source, id: id)
            }
            if let value = try? await item.load(.stringValue), !value.isEmpty {
                switch item.commonKey {
                case .commonKeyTitle: track.title = value
                case .commonKeyArtist: track.artist = value
                case .commonKeyAlbumName: track.album = value
                default: break
                }
            }
        }
        track.lyrics = sidecarLyrics(url)
        let fullMetadata = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
        for item in fullMetadata {
            try Task.checkCancellation()
            let key = item.identifier?.rawValue ?? ""
            guard let role = AudioTags.role(for: key) else { continue }
            switch role {
            case .track:
                if track.trackNumber == nil { track.trackNumber = await number(from: item) }
            case .disc:
                if track.discNumber == nil { track.discNumber = await number(from: item) }
            case .albumArtist:
                if track.albumArtist == nil, let value = try? await item.load(.stringValue), !value.isEmpty { track.albumArtist = value }
            case .genre:
                if track.genre == nil, let value = try? await item.load(.stringValue) { track.genre = AudioTags.genre(from: value) }
            case .year:
                if track.year == nil, let value = try? await item.load(.stringValue) { track.year = AudioTags.year(from: value) }
            case .compilation:
                if track.compilation != true { track.compilation = await compilation(from: item) }
            }
        }
        track.catalogVersion = AudioTags.catalogVersion
        return track
    }

    private func number(from item: AVMetadataItem) async -> Int? {
        if let text = try? await item.load(.stringValue), let value = AudioTags.number(from: text) { return value }
        if let data = try? await item.load(.dataValue), let value = AudioTags.number(from: data) { return value }
        if let number = try? await item.load(.numberValue), number.intValue > 0 { return number.intValue }
        return nil
    }

    private func compilation(from item: AVMetadataItem) async -> Bool {
        if let text = try? await item.load(.stringValue), AudioTags.compilation(from: text) { return true }
        if let data = try? await item.load(.dataValue), AudioTags.compilation(from: data) { return true }
        if let number = try? await item.load(.numberValue), number.intValue != 0 { return true }
        return false
    }

    private func storeThumbnail(at url: URL, id: UUID) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return storeThumbnail(source, id: id)
    }

    private func storeThumbnail(_ source: CGImageSource, id: UUID) -> String? {
        let name = id.uuidString + ".artwork"
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 700,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return name
    }

    /// Path of `file` relative to `directory`.
    /// Strips a leading `/private` so `/var/...` and `/private/var/...` (and file-provider coordinated URLs) still match.
    static func relativePath(for file: URL, in directory: URL) -> String? {
        let filePath = canonicalPath(file)
        let directoryPath = canonicalPath(directory)
        guard filePath != directoryPath else { return nil }
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        let relative = String(filePath.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.hasPrefix("/") else { return nil }
        return relative
    }

    static func canonicalPath(_ url: URL) -> String {
        var path = url.path.precomposedStringWithCanonicalMapping
        if path.hasPrefix("/private/") {
            path = String(path.dropFirst("/private".count))
        }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func sidecarLyrics(_ url: URL) -> String? {
        let lrc = url.deletingPathExtension().appendingPathExtension("lrc")
        guard let values = try? lrc.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? 0) < 1_000_000 else { return nil }
        var text: String?, error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: lrc, options: [], error: &error) { file in
            text = try? String(contentsOf: file, encoding: .utf8)
        }
        return text
    }

}
