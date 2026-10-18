import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot = LibrarySnapshot()
    @Published var errorMessage: String?
    @Published private(set) var importing = false
    @Published private(set) var progressText = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var scanSummary: String?
    let root: URL
    private let scanner: AudioScanner
    private var job: Task<Void, Never>?
    private var indexURL: URL { root.appendingPathComponent("library.json") }
    var tracks: [Track] { snapshot.tracks }
    static let extensions = AudioScanner.extensions

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
        self.scanner = AudioScanner(root: self.root)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: indexURL))
            }
        } catch { errorMessage = "资料库读取失败：\(error.localizedDescription)" }
    }

    func url(for track: Track) -> URL {
        if let id = track.folderID, let folder = snapshot.folders.first(where: { $0.id == id }),
           let base = try? resolve(folder), let path = track.relativePath {
            return base.appendingPathComponent(path)
        }
        return root.appendingPathComponent(track.filename)
    }

    func resolve(_ folder: MusicFolder) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: folder.bookmark, options: .withoutUI,
                       relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    @discardableResult
    private func persist(_ candidate: LibrarySnapshot) -> Bool {
        do {
            try JSONEncoder().encode(candidate).write(to: indexURL, options: .atomic)
            snapshot = candidate; return true
        } catch { errorMessage = "资料库保存失败：\(error.localizedDescription)"; return false }
    }

    func remember(id: UUID?, position: Double) {
        var updated = snapshot
        updated.currentID = id
        updated.position = position.isFinite ? max(0, position) : 0
        persist(updated)
    }

    func rememberQueue(_ ids: [UUID]) { var s = snapshot; s.queueIDs = ids; persist(s) }
    func toggleFavorite(_ track: Track) {
        var s = snapshot
        guard let i = s.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        s.tracks[i].favorite.toggle(); persist(s)
    }

    func createPlaylist(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var s = snapshot; s.playlists.append(Playlist(name: name)); persist(s)
    }
    func add(_ track: Track, to playlist: Playlist) {
        var s = snapshot
        guard let i = s.playlists.firstIndex(where: { $0.id == playlist.id }),
              !s.playlists[i].trackIDs.contains(track.id) else { return }
        s.playlists[i].trackIDs.append(track.id); persist(s)
    }
    func removePlaylist(_ playlist: Playlist) {
        var s = snapshot; s.playlists.removeAll { $0.id == playlist.id }; persist(s)
    }
    func removeFromPlaylist(_ track: Track, playlist: Playlist) {
        var s = snapshot
        guard let i = s.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        s.playlists[i].trackIDs.removeAll { $0 == track.id }; persist(s)
    }

    func remove(_ track: Track) {
        var s = snapshot
        s.tracks.removeAll { $0.id == track.id }; s.queueIDs.removeAll { $0 == track.id }
        for i in s.playlists.indices { s.playlists[i].trackIDs.removeAll { $0 == track.id } }
        if let folderID = track.folderID, let path = track.relativePath,
           let i = s.folders.firstIndex(where: { $0.id == folderID }) { s.folders[i].excludedPaths.append(path) }
        if s.currentID == track.id { s.currentID = nil; s.position = 0 }
        if persist(s), track.folderID == nil {
            do { try FileManager.default.removeItem(at: root.appendingPathComponent(track.filename)) }
            catch { errorMessage = "条目已移除，副本清理失败：\(error.localizedDescription)" }
        }
    }

    func addFolder(_ url: URL) async {
        guard !importing else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            if let old = snapshot.folders.first(where: { (try? resolve($0).standardizedFileURL) == url.standardizedFileURL }) {
                await scanFolder(old.id); return
            }
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            var s = snapshot
            let folder = MusicFolder(id: UUID(), name: url.lastPathComponent, bookmark: bookmark)
            s.folders.append(folder)
            if persist(s) { await scanFolder(folder.id) }
        } catch { errorMessage = "文件夹授权失败：\(error.localizedDescription)" }
    }

    func removeFolder(_ folder: MusicFolder) {
        guard !importing else { return }
        var s = snapshot
        let removed = Set(s.tracks.filter { $0.folderID == folder.id }.map(\.id))
        s.folders.removeAll { $0.id == folder.id }; s.tracks.removeAll { removed.contains($0.id) }
        s.queueIDs.removeAll { removed.contains($0) }
        for i in s.playlists.indices { s.playlists[i].trackIDs.removeAll { removed.contains($0) } }
        if let id = s.currentID, removed.contains(id) { s.currentID = nil; s.position = 0 }
        persist(s)
    }

    func startScan(_ id: UUID) { guard !importing else { return }; job = Task { await scanFolder(id) } }
    func startImport(_ urls: [URL]) { guard !importing else { return }; job = Task { await importFiles(urls) } }
    func startAddFolders(_ urls: [URL]) {
        guard !importing else { return }
        job = Task { for url in urls { if Task.isCancelled { break }; await addFolder(url) } }
    }
    func cancelScan() { job?.cancel() }

    func scanFolder(_ id: UUID) async {
        guard !importing, let folder = snapshot.folders.first(where: { $0.id == id }) else { return }
        importing = true; progress = 0; progressText = "正在读取 \(folder.name)…"
        defer { importing = false }
        do {
            let url = try resolve(folder)
            let result = try await scanner.scan(url: url, folder: folder,
                existing: tracks.filter { $0.folderID == id }) { [weak self] done, total, name in
                await self?.updateProgress(done, total: total, name: name)
            }
            try Task.checkCancellation()
            var s = snapshot
            let oldIDs = Set(s.tracks.map(\.id))
            let excluded = Set(s.folders.first(where: { $0.id == id })?.excludedPaths ?? [])
            let accepted = result.tracks.filter { !excluded.contains($0.relativePath ?? "") }
            let added = accepted.filter { !oldIDs.contains($0.id) }.count
            // Keep favorites/playlist membership edited while the worker was running.
            for var track in accepted {
                if let i = s.tracks.firstIndex(where: { $0.id == track.id }) {
                    track.favorite = s.tracks[i].favorite; s.tracks[i] = track
                } else { s.tracks.append(track) }
            }
            for i in s.tracks.indices where s.tracks[i].folderID == id {
                s.tracks[i].missing = !result.seen.contains(s.tracks[i].relativePath ?? "")
            }
            if let i = s.folders.firstIndex(where: { $0.id == id }) {
                s.folders[i].lastScan = Date()
                s.folders[i].scanError = result.failures.isEmpty ? nil : "\(result.failures.count) 个文件无法读取"
                // Recreate bookmark after resolution to refresh moved/stale provider references.
                let scoped = url.startAccessingSecurityScopedResource()
                if let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    s.folders[i].bookmark = fresh
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            if persist(s) {
                scanSummary = "扫描完成：新增 \(added) 首，已存在 \(result.skipped) 首，无法读取 \(result.failures.count) 个"
                progress = 1; progressText = scanSummary ?? ""
            }
        } catch is CancellationError { scanSummary = "已取消扫描，资料库保持不变" }
        catch {
            var s = snapshot
            if let i = s.folders.firstIndex(where: { $0.id == id }) { s.folders[i].scanError = error.localizedDescription }
            persist(s)
            errorMessage = "无法扫描 \(folder.name)：\(error.localizedDescription)。请检查文件夹权限或重新添加。"
        }
    }

    private func updateProgress(_ done: Int, total: Int, name: String) {
        progress = Double(done) / Double(max(1, total)); progressText = "\(done)/\(total) · \(name)"
    }

    func importFiles(_ urls: [URL]) async {
        guard !importing else { return }
        importing = true; progress = 0
        defer { importing = false }
        var failures: [String] = [], added = 0
        for (i, source) in urls.enumerated() {
            if Task.isCancelled { break }
            updateProgress(i + 1, total: urls.count, name: source.lastPathComponent)
            do {
                let track = try await scanner.importCopy(source)
                if !tracks.contains(where: { $0.folderID == nil && $0.filename == track.filename }) {
                    var s = snapshot; s.tracks.append(track)
                    if persist(s) { added += 1 }
                    else { try? FileManager.default.removeItem(at: root.appendingPathComponent(track.filename)) }
                }
            } catch is CancellationError { break }
            catch { failures.append("\(source.lastPathComponent)：\(error.localizedDescription)") }
        }
        scanSummary = "导入 \(added) 首歌曲"
        if !failures.isEmpty { errorMessage = failures.prefix(8).joined(separator: "\n") }
    }
}
