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
    private var playbackURL: URL { root.appendingPathComponent("playback.json") }
    /// Resume point, queue, shuffle, and repeat. Not `@Published`, so playback ticks do not refresh the library UI.
    private(set) var playback = PlaybackState()
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
            loadPlayback()
        } catch { errorMessage = "资料库读取失败：\(error.localizedDescription)" }
    }

    private func loadPlayback() {
        if let data = try? Data(contentsOf: playbackURL),
           let state = try? JSONDecoder().decode(PlaybackState.self, from: data) {
            playback = state
            return
        }
        playback = PlaybackState(currentID: snapshot.currentID, position: snapshot.position, queueIDs: snapshot.queueIDs)
        if playback.currentID != nil || playback.position != 0 || !playback.queueIDs.isEmpty {
            writePlaybackFile()
        }
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
        let resolved = try URL(resolvingBookmarkData: folder.bookmark, options: .withoutUI,
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale { noteResolvedBookmark(for: folder.id, url: resolved, stale: true) }
        return resolved
    }

    /// Rewrites a security-scoped bookmark after the system reports it stale. A fresh bookmark is left untouched.
    func noteResolvedBookmark(for id: UUID, url: URL, stale: Bool) {
        guard stale else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var updated = snapshot
        guard let index = updated.folders.firstIndex(where: { $0.id == id }), updated.folders[index].bookmark != data else { return }
        updated.folders[index].bookmark = data
        persist(updated)
    }

    @discardableResult
    private func persist(_ candidate: LibrarySnapshot) -> Bool {
        do {
            try JSONEncoder().encode(candidate).write(to: indexURL, options: .atomic)
            snapshot = candidate; return true
        } catch { errorMessage = "资料库保存失败：\(error.localizedDescription)"; return false }
    }

    func remember(id: UUID?, position: Double) {
        playback.currentID = id
        playback.position = position.isFinite ? max(0, position) : 0
        writePlaybackFile()
    }

    func rememberQueue(_ ids: [UUID], contextOrder: [UUID]? = nil, shuffle: Bool? = nil) {
        playback.queueIDs = ids
        if let contextOrder { playback.contextOrder = contextOrder }
        if let shuffle { playback.shuffle = shuffle }
        writePlaybackFile()
    }

    func rememberTransport(shuffle: Bool, repeatMode: RepeatMode) {
        playback.shuffle = shuffle
        playback.repeatMode = repeatMode
        writePlaybackFile()
    }

    private func writePlaybackFile() {
        try? JSONEncoder().encode(playback).write(to: playbackURL, options: .atomic)
    }
    func toggleFavorite(_ track: Track) {
        var s = snapshot
        guard let i = s.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        s.tracks[i].favorite.toggle(); persist(s)
    }

    @discardableResult
    func createPlaylist(_ name: String) -> Playlist? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var s = snapshot
        let list = Playlist(name: name); s.playlists.append(list)
        return persist(s) ? list : nil
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
        s.playlists[i].trackIDs.removeAll { $0 == track.id }
        if s.playlists[i].coverTrackID == track.id { s.playlists[i].coverTrackID = nil }
        persist(s)
    }

    func rename(_ playlist: Playlist, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var s = snapshot
        guard let i = s.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        s.playlists[i].name = name
        persist(s)
    }

    func moveTracks(in playlist: Playlist, displayed: [UUID], from offsets: IndexSet, to destination: Int) {
        var ids = displayed
        let moving = offsets.sorted().compactMap { ids.indices.contains($0) ? ids[$0] : nil }
        for index in offsets.sorted(by: >) where ids.indices.contains(index) { ids.remove(at: index) }
        let insertion = min(max(0, destination - offsets.filter { $0 < destination }.count), ids.count)
        ids.insert(contentsOf: moving, at: insertion)
        let hidden = playlist.trackIDs.filter { !Set(displayed).contains($0) }
        var s = snapshot
        guard let i = s.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        s.playlists[i].trackIDs = ids + hidden
        persist(s)
    }

    func setCover(_ track: Track, for playlist: Playlist) {
        var s = snapshot
        guard let i = s.playlists.firstIndex(where: { $0.id == playlist.id }), s.playlists[i].trackIDs.contains(track.id) else { return }
        s.playlists[i].coverTrackID = track.id
        persist(s)
    }

    func coverTrack(for playlist: Playlist) -> Track? {
        if let id = playlist.coverTrackID, let track = tracks.first(where: { $0.id == id }) { return track }
        let members = playlist.trackIDs.compactMap { id in tracks.first { $0.id == id } }
        return members.first { $0.artworkFilename != nil } ?? members.first
    }

    func recordPlay(id: UUID) {
        var s = snapshot
        guard let i = s.tracks.firstIndex(where: { $0.id == id }) else { return }
        s.tracks[i].playCount += 1
        s.tracks[i].lastPlayed = Date()
        persist(s)
    }

    func startImportPlaylists(_ urls: [URL]) {
        guard !importing else { return }
        var notes: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = PlaylistExchange.read(url) else {
                notes.append("\(url.lastPathComponent) 无法读取")
                continue
            }
            let entries = PlaylistExchange.parse(text)
            let name = url.deletingPathExtension().lastPathComponent
            guard let list = createPlaylist(name) else { continue }
            var matched = 0
            for entry in entries {
                if let track = PlaylistExchange.match(entry, in: tracks) {
                    add(track, to: list)
                    matched += 1
                }
            }
            notes.append("\(name)：匹配 \(matched) 首，未匹配 \(entries.count - matched) 条")
        }
        if !notes.isEmpty { scanSummary = notes.joined(separator: "\n") }
    }

    func remove(_ track: Track) {
        var s = snapshot
        s.tracks.removeAll { $0.id == track.id }
        for i in s.playlists.indices {
            s.playlists[i].trackIDs.removeAll { $0 == track.id }
            if s.playlists[i].coverTrackID == track.id { s.playlists[i].coverTrackID = nil }
        }
        if let folderID = track.folderID, let path = track.relativePath,
           let i = s.folders.firstIndex(where: { $0.id == folderID }) { s.folders[i].excludedPaths.append(path) }
        playback.queueIDs.removeAll { $0 == track.id }
        playback.contextOrder.removeAll { $0 == track.id }
        if playback.currentID == track.id { playback.currentID = nil; playback.position = 0 }
        writePlaybackFile()
        s.currentID = playback.currentID
        s.position = playback.position
        s.queueIDs = playback.queueIDs
        if persist(s), RemovalNotice.deletesAppCopy(track) {
            do { try FileManager.default.removeItem(at: root.appendingPathComponent(track.filename)) }
            catch { errorMessage = "条目已移除，副本清理失败：\(error.localizedDescription)" }
            ArtworkCache.shared.removeAll()
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
        for i in s.playlists.indices {
            s.playlists[i].trackIDs.removeAll { removed.contains($0) }
            if let cover = s.playlists[i].coverTrackID, removed.contains(cover) { s.playlists[i].coverTrackID = nil }
        }
        playback.queueIDs.removeAll { removed.contains($0) }
        playback.contextOrder.removeAll { removed.contains($0) }
        if let id = playback.currentID, removed.contains(id) { playback.currentID = nil; playback.position = 0 }
        writePlaybackFile()
        s.currentID = playback.currentID
        s.position = playback.position
        s.queueIDs = playback.queueIDs
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
                    track.favorite = s.tracks[i].favorite
                    track.playCount = s.tracks[i].playCount
                    track.lastPlayed = s.tracks[i].lastPlayed
                    s.tracks[i] = track
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
                ArtworkCache.shared.removeAll()
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
        ArtworkCache.shared.removeAll()
        scanSummary = "导入 \(added) 首歌曲"
        if !failures.isEmpty { errorMessage = failures.prefix(8).joined(separator: "\n") }
    }
}
