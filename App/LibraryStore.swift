import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot = LibrarySnapshot()
    @Published var errorMessage: String?
    @Published private(set) var musicBrainzNotice: String?
    /// The song 更新封面 is looking up, and how the last one ended.
    @Published private(set) var coverUpdating: UUID?
    @Published var coverUpdateResult: CoverUpdate?
    @Published private(set) var importing = false
    @Published private(set) var progressText = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var scanSummary: String?
    let root: URL
    private let scanner: AudioScanner
    private var job: Task<Void, Never>?
    private var attemptedCatalogMigration = false
    private(set) var catalogMigrationJob: Task<Void, Never>?
    private(set) var albumLookupJob: Task<Void, Never>?
    private var indexURL: URL { root.appendingPathComponent("library.json") }
    private var backupURL: URL { root.appendingPathComponent("library.backup.json") }
    private var playbackURL: URL { root.appendingPathComponent("playback.json") }
    /// Resume point, queue, shuffle, and repeat. Not `@Published`, so playback ticks do not refresh the library UI.
    private(set) var playback = PlaybackState()
    var tracks: [Track] { snapshot.tracks }
    /// ID → track index for render paths. Queues, playlists and pages used to
    /// linear-scan `tracks` for every ID on every view update — O(n²) on a
    /// large library. The index is rebuilt wherever `snapshot` is replaced
    /// (init and `persist`, the only two places), so it cannot go stale.
    private(set) var trackByID: [UUID: Track] = [:]
    /// Library-wide groupings the home, album and artist pages render.
    /// These used to be recomputed inside `LibraryView.body` — album
    /// grouping with localized sorts, a full-library filter per artist
    /// row — whenever the player published (play, pause, track change).
    /// They are rebuilt together with `trackByID` wherever `snapshot` is
    /// replaced, so they cannot go stale either.
    private(set) var albumGroups: [AlbumGroup] = []
    /// `albumGroups` ordered most-recently-added first, for the home page.
    private(set) var recentAlbums: [AlbumGroup] = []
    /// Unique artist names, sorted the way the artist index presents them.
    private(set) var artistNames: [String] = []
    /// Tracks keyed by normalized artist name; see `tracks(forArtist:)`.
    private var artistTracks: [String: [Track]] = [:]
    private(set) var favoriteTracks: [Track] = []
    private(set) var recentlyPlayed: [Track] = []
    /// Search grouping for the current catalog and query. Cleared in `rebuildIndex`.
    private var cachedSearch: (query: String, results: SearchResults)?
    private let playbackCheckpoint = PlaybackCheckpoint()
    static let extensions = AudioScanner.extensions

    func track(_ id: UUID?) -> Track? {
        guard let id else { return nil }
        return trackByID[id]
    }

    /// The tracks for `ids`, in the order asked for, skipping unknown IDs.
    func tracks(for ids: [UUID]) -> [Track] {
        ids.compactMap { trackByID[$0] }
    }

    /// The tracks credited to `artist`, in library order. Matching is by
    /// normalized name, the same comparison the artist pages used to run
    /// as a full-library filter for every row on every render.
    func tracks(forArtist artist: String) -> [Track] {
        artistTracks[AudioTags.normalized(artist)] ?? []
    }

    private func rebuildIndex() {
        trackByID = Dictionary(snapshot.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cachedSearch = nil
    }

    /// Memoized for the current catalog. `LibraryView` calls this from `body`;
    /// play/pause must not regroup the library on every refresh.
    func searchResults(matching query: String) -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cachedSearch, cachedSearch.query == trimmed { return cachedSearch.results }
        let results = SearchResults.group(tracks: tracks, query: trimmed)
        cachedSearch = (trimmed, results)
        return results
    }

    /// Rebuilds the derived collections declared above from `snapshot`.
    /// Called at exactly the same two places as `rebuildIndex()`.
    private func rebuildDerived() {
        let all = snapshot.tracks
        albumGroups = AlbumGroup.groups(all)
        recentAlbums = albumGroups.sorted { $0.latest > $1.latest }
        artistNames = Array(Set(all.flatMap(\.artistNames)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var byArtist: [String: [Track]] = [:]
        for track in all {
            for name in track.artistNames {
                byArtist[AudioTags.normalized(name), default: []].append(track)
            }
        }
        artistTracks = byArtist
        favoriteTracks = all.filter(\.favorite)
        recentlyPlayed = all.filter { $0.lastPlayed != nil }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
        self.scanner = AudioScanner(root: self.root)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                do {
                    snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: indexURL))
                } catch {
                    // A corrupt main file must not take the whole library
                    // with it: fall back to the last known-good backup and
                    // rewrite the main file from it.
                    guard let data = try? Data(contentsOf: backupURL),
                          let recovered = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) else { throw error }
                    snapshot = recovered
                    errorMessage = "资料库主文件损坏，已从备份恢复"
                    persist(snapshot)
                }
            }
            rebuildIndex()
            rebuildDerived()
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
            var candidate = candidate
            candidate.version = LibrarySnapshot.currentVersion
            rotateBackup()
            try JSONEncoder().encode(candidate).write(to: indexURL, options: .atomic)
            snapshot = candidate
            rebuildIndex()
            rebuildDerived()
            return true
        } catch { errorMessage = "资料库保存失败：\(error.localizedDescription)"; return false }
    }

    /// Keeps the last known-good main file as `library.backup.json` before
    /// it is replaced. A file that no longer decodes never rotates in, so a
    /// corrupt main cannot overwrite a good backup.
    private func rotateBackup() {
        guard let data = try? Data(contentsOf: indexURL),
              (try? JSONDecoder().decode(LibrarySnapshot.self, from: data)) != nil else { return }
        try? data.write(to: backupURL, options: .atomic)
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
        playbackCheckpoint.writeNow(playback, to: playbackURL)
    }

    /// Periodic progress checkpoint. Memory updates immediately; the file is
    /// written on a serial queue so the 5-second tick does not encode JSON
    /// on the main thread. Pause, seek, and backgrounding still use
    /// `remember`, which waits until the file is replaced.
    func checkpointPlayback(id: UUID?, position: Double) {
        playback.currentID = id
        playback.position = position.isFinite ? max(0, position) : 0
        playbackCheckpoint.writeLater(playback, to: playbackURL)
    }
    /// Only the app catalog and thumbnail cache are written. Never resolves an audio URL.
    @discardableResult
    func applyMusicBrainz(_ candidate: ReleaseCandidate, reviewed track: Track,
                         client: MusicBrainzClient = .shared) async throws -> Bool {
        guard !importing, trackByID[track.id] == track else {
            throw MusicBrainzApplyError.changed
        }
        var artwork: String?
        var coverNotice: String?
        if track.artworkFilename == nil {
            do {
                if let data = try await client.frontCover(for: candidate) {
                    try Task.checkCancellation()
                    artwork = await scanner.storeThumbnail(data: data)
                    if artwork == nil { coverNotice = "信息已保存；封面无法读取，保持无封面。" }
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw error }
            catch { coverNotice = "信息已保存；封面下载失败，可稍后重试。" }
        }
        // Recheck after network/thumbnail suspension so a scan, deletion or edit cannot be overwritten.
        guard !Task.isCancelled, !importing, trackByID[track.id] == track,
              let index = snapshot.tracks.firstIndex(where: { $0.id == track.id }) else {
            if let artwork { try? FileManager.default.removeItem(at: root.appendingPathComponent(artwork)) }
            throw MusicBrainzApplyError.changed
        }
        var updated = snapshot
        updated.tracks[index] = ReleaseMatching.applying(candidate, to: track)
        if let artwork { updated.tracks[index].artworkFilename = artwork }
        guard persist(updated) else {
            if let artwork { try? FileManager.default.removeItem(at: root.appendingPathComponent(artwork)) }
            return false
        }
        musicBrainzNotice = coverNotice
        return true
    }

    /// The 自动补全专辑与封面 switch in 音乐文件夹. On unless the user turned it off.
    static let albumLookupKey = "autoAlbumLookup"
    /// Bumped when matching improves, so songs looked up under older rules are asked once more.
    /// 2: traditional and simplified Chinese match. 3: covers from Apple's catalog.
    static let albumLookupRules = 3
    private var albumLookupEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.albumLookupKey) as? Bool ?? true
    }

    /// Starts the background lookup unless one is already running; a running
    /// one picks up songs added since, as it re-reads the library each step.
    func startAlbumLookup(client: MusicBrainzClient = .shared) {
        guard !ScreenshotFixture.enabled, albumLookupEnabled, albumLookupJob == nil else { return }
        albumLookupJob = Task {
            await lookUpAlbums(client: client)
            albumLookupJob = nil
        }
    }

    /// The next song to ask MusicBrainz about: one with no album tag, or one
    /// whose album has no artwork on any of its songs. Each is asked once per
    /// version of the matching rules. `skipped` holds songs and albums whose
    /// cover failed to download in this pass.
    private func nextAlbumLookup(skipping skipped: Set<String>) -> Track? {
        let covered = Set(tracks.filter { $0.artworkFilename != nil }.map(\.albumID))
        return tracks.first {
            $0.available && !skipped.contains($0.id.uuidString) && !skipped.contains($0.albumID)
                && !($0.albumLookedUp == true && ($0.albumLookupRules ?? 1) >= Self.albumLookupRules)
                && ReleaseMatching.known($0.title)
                && ReleaseMatching.known($0.artist) && (!$0.hasAlbum || !covered.contains($0.albumID))
        }
    }

    /// Fills what tags left blank, one song at a time: see `lookUp`. Nothing
    /// found leaves the song a single named after itself, with the
    /// placeholder cover. A song whose search or cover went unanswered keeps
    /// what was found, stays unmarked for the next launch and is passed
    /// over, so one unreachable service never holds up the rest. When
    /// MusicBrainz and the cover services all fail the device is taken to be
    /// offline and the pass stops. Turning the switch off stops it after the
    /// current song. Only the app catalog and thumbnail cache are written.
    func lookUpAlbums(client: MusicBrainzClient = .shared) async {
        var skipped = Set<String>()
        while !Task.isCancelled, albumLookupEnabled {
            while importing {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            guard let track = nextAlbumLookup(skipping: skipped) else { return }
            let lookup = await lookUp(track, client: client, skipping: skipped)
            if lookup.searchFailed && lookup.coverFailed { return }
            if !lookup.complete { skipped.formUnion([track.id.uuidString, lookup.updated.albumID]) }
            if save(lookup, for: track) == .failed { return }
        }
    }

    /// One song's lookup. `searchFailed` and `coverFailed` mean a request went
    /// unanswered, so the song is not marked as looked up.
    private struct AlbumLookup {
        var updated: Track
        var fillsAlbum: Bool
        var artwork: String?
        var searchFailed = false
        var coverFailed = false
        var complete: Bool { !searchFailed && !coverFailed }
    }

    /// Asks MusicBrainz for the song: an untagged song gets the album
    /// `ReleaseMatching.automaticAlbum` picks. A song with no artwork on its
    /// album gets that release's Cover Art Archive front, else Apple's cover
    /// for the same artist and album, or for a song with no album, the cover
    /// of an album Apple lists the same song under. A failed search still
    /// tries Apple with what the tags say.
    private func lookUp(_ track: Track, client: MusicBrainzClient, skipping skipped: Set<String>) async -> AlbumLookup {
        let fillsAlbum = !track.hasAlbum
        var release: ReleaseCandidate?
        var searchFailed = false
        do {
            let candidates = try await client.candidates(for: track)
            release = fillsAlbum ? ReleaseMatching.automaticAlbum(candidates) : ReleaseMatching.automaticCover(candidates)
        } catch { searchFailed = true }
        let updated = release.map { fillsAlbum ? ReleaseMatching.fillingAlbum($0, to: track) : track } ?? track
        var lookup = AlbumLookup(updated: updated, fillsAlbum: fillsAlbum, searchFailed: searchFailed)
        // The album's cover already failed in this pass.
        lookup.coverFailed = updated.hasAlbum && skipped.contains(updated.albumID)
        guard !lookup.coverFailed, track.artworkFilename == nil,
              !tracks.contains(where: { $0.albumID == updated.albumID && $0.artworkFilename != nil }) else { return lookup }
        var data: Data?
        if let release {
            do { data = try await client.frontCover(for: release) } catch { lookup.coverFailed = true }
        }
        if data == nil {
            do {
                data = updated.hasAlbum
                    ? try await client.appleCover(artist: updated.albumArtistName, album: updated.album)
                    : try await client.appleSongCover(title: track.title, artist: track.artist)
            } catch { lookup.coverFailed = true }
        }
        if let data {
            lookup.artwork = await scanner.storeThumbnail(data: data)
            lookup.coverFailed = false
        }
        return lookup
    }

    private enum LookupSave { case saved, changed, failed }

    /// Writes a lookup to the song and, for a tagged album, the album's other
    /// songs without artwork. A scan or edit during the requests wins; the
    /// song is asked again from its new state.
    private func save(_ lookup: AlbumLookup, for track: Track) -> LookupSave {
        func discard() {
            if let artwork = lookup.artwork { try? FileManager.default.removeItem(at: root.appendingPathComponent(artwork)) }
        }
        guard !Task.isCancelled, !importing, trackByID[track.id] == track else { discard(); return .changed }
        if !lookup.complete, lookup.artwork == nil, lookup.updated == track { return .saved }
        var s = snapshot
        for i in s.tracks.indices where s.tracks[i].id == track.id
            || (!lookup.fillsAlbum && s.tracks[i].albumID == track.albumID) {
            if s.tracks[i].id == track.id { s.tracks[i] = lookup.updated }
            if s.tracks[i].artworkFilename == nil, let artwork = lookup.artwork { s.tracks[i].artworkFilename = artwork }
            if !lookup.complete { continue }
            s.tracks[i].albumLookedUp = true
            s.tracks[i].albumLookupRules = Self.albumLookupRules
        }
        guard persist(s) else { discard(); return .failed }
        if lookup.artwork != nil { ArtworkCache.shared.removeAll() }
        return .saved
    }

    /// 更新封面 in a song's menu, one song at a time.
    func startCoverUpdate(_ track: Track, client: MusicBrainzClient = .shared) {
        guard coverUpdating == nil else { return }
        coverUpdating = track.id
        Task {
            let result = await updateCover(track, client: client)
            coverUpdating = nil
            coverUpdateResult = result
        }
    }

    /// The background lookup's steps for one song, asked again even if it was
    /// looked up before and whether or not the switch is on. Nil when the
    /// catalog could not be saved, which `errorMessage` already reports.
    func updateCover(_ track: Track, client: MusicBrainzClient = .shared) async -> CoverUpdate? {
        guard ReleaseMatching.known(track.title), ReleaseMatching.known(track.artist) else { return .notFound }
        // Another song of the album already has a cover: share it.
        if track.hasAlbum, track.artworkFilename == nil,
           let cover = tracks.first(where: { $0.albumID == track.albumID && $0.artworkFilename != nil })?.artworkFilename {
            var s = snapshot
            guard let i = s.tracks.firstIndex(where: { $0.id == track.id }) else { return .changed }
            s.tracks[i].artworkFilename = cover
            return persist(s) ? .found : nil
        }
        let lookup = await lookUp(track, client: client, skipping: [])
        switch save(lookup, for: track) {
        case .failed: return nil
        case .changed: return trackByID[track.id]?.artworkFilename != nil ? .found : .changed
        case .saved:
            if lookup.artwork != nil { return .found }
            return lookup.complete ? .notFound : .unreachable
        }
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
        add([track], to: playlist)
    }

    func add(_ tracks: [Track], to playlist: Playlist) {
        var s = snapshot
        guard let i = s.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        var ids = s.playlists[i].trackIDs
        var changed = false
        for track in tracks where !ids.contains(track.id) {
            ids.append(track.id)
            changed = true
        }
        guard changed else { return }
        s.playlists[i].trackIDs = ids
        persist(s)
    }
    func removePlaylist(_ playlist: Playlist) {
        var s = snapshot
        let cover = s.playlists.first { $0.id == playlist.id }?.customArtworkFilename
        s.playlists.removeAll { $0.id == playlist.id }
        if persist(s), let cover { try? FileManager.default.removeItem(at: root.appendingPathComponent(cover)) }
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
        let previous = s.playlists[i].customArtworkFilename
        s.playlists[i].customArtworkFilename = nil
        s.playlists[i].coverTrackID = track.id
        if persist(s), let previous { try? FileManager.default.removeItem(at: root.appendingPathComponent(previous)) }
    }

    @discardableResult
    func setPlaylistArtwork(_ data: Data, for playlist: Playlist) -> Bool {
        guard data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1000,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { errorMessage = "无法读取封面图片，请选择 20MB 以内的图片。"; return false }
        var s = snapshot
        guard let i = s.playlists.firstIndex(where: { $0.id == playlist.id }) else { return false }
        let name = "playlist-" + UUID().uuidString + ".jpg"
        let url = root.appendingPathComponent(name)
        guard let target = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { return false }
        let previous = s.playlists[i].customArtworkFilename
        s.playlists[i].customArtworkFilename = name
        guard persist(s) else { try? FileManager.default.removeItem(at: url); return false }
        if let previous { try? FileManager.default.removeItem(at: root.appendingPathComponent(previous)) }
        ArtworkCache.shared.removeAll()
        return true
    }

    func resetPlaylistArtwork(_ playlist: Playlist) {
        var s = snapshot
        guard let i = s.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let previous = s.playlists[i].customArtworkFilename
        s.playlists[i].customArtworkFilename = nil
        s.playlists[i].coverTrackID = nil
        if persist(s), let previous { try? FileManager.default.removeItem(at: root.appendingPathComponent(previous)) }
        ArtworkCache.shared.removeAll()
    }

    /// Every directory with direct audio children becomes one playlist, preserving
    /// user-defined folders instead of inferring grouping from album tags.
    func createPlaylistsFromFolder(_ folder: MusicFolder) {
        let members = tracks.filter { $0.folderID == folder.id && $0.available }
        let groups = Dictionary(grouping: members) { (($0.relativePath ?? "") as NSString).deletingLastPathComponent }
        var s = snapshot
        for directory in groups.keys.sorted() {
            let songs = (groups[directory] ?? []).sorted { ($0.relativePath ?? "") < ($1.relativePath ?? "") }
            let i: Int
            if let existing = s.playlists.firstIndex(where: { $0.sourceFolderID == folder.id && $0.sourceDirectory == directory }) {
                i = existing
            } else {
                var list = Playlist(name: directory.isEmpty ? folder.name : directory)
                list.sourceFolderID = folder.id
                list.sourceDirectory = directory
                s.playlists.append(list)
                i = s.playlists.count - 1
            }
            let known = Set(s.playlists[i].trackIDs)
            s.playlists[i].trackIDs += songs.map(\.id).filter { !known.contains($0) }
        }
        if persist(s) { scanSummary = "已按文件夹整理 \(groups.count) 个歌单，共 \(members.count) 首歌曲" }
    }

    func startFolderPlaylists(_ urls: [URL]) {
        guard !importing else { return }
        job = Task {
            for url in urls {
                if Task.isCancelled { break }
                await addFolder(url)
                if Task.isCancelled { break }
                if let folder = snapshot.folders.first(where: { (try? resolve($0).standardizedFileURL) == url.standardizedFileURL }), folder.lastScan != nil {
                    createPlaylistsFromFolder(folder)
                }
            }
        }
    }

    func coverTrack(for playlist: Playlist) -> Track? {
        if let track = track(playlist.coverTrackID) { return track }
        let members = tracks(for: playlist.trackIDs)
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

    /// Songs re-read by the migration may only now have what the lookup
    /// needs, so the lookup is started again once it finishes.
    func startCatalogMigration(client: MusicBrainzClient = .shared) {
        guard !ScreenshotFixture.enabled, !attemptedCatalogMigration, catalogMigrationJob == nil else { return }
        catalogMigrationJob = Task {
            await migrateCatalogIfNeeded()
            startAlbumLookup(client: client)
        }
    }

    /// Once per launch, wait for imports and upgrade only stale catalog sources.
    /// Failures keep their old version so the next launch can retry.
    func migrateCatalogIfNeeded() async {
        guard !ScreenshotFixture.enabled, !attemptedCatalogMigration else { return }
        while importing {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
        guard !Task.isCancelled, !attemptedCatalogMigration else { return }
        attemptedCatalogMigration = true
        func stale(_ track: Track) -> Bool { (track.catalogVersion ?? 0) < AudioTags.catalogVersion }
        let folderIDs = Set(tracks.filter(stale).compactMap(\.folderID))
        for folder in snapshot.folders where folderIDs.contains(folder.id) {
            if Task.isCancelled { return }
            await scanFolder(folder.id)
        }
        let copies = tracks.filter { $0.folderID == nil && stale($0) }
        guard !copies.isEmpty, !Task.isCancelled, !importing else { return }
        importing = true
        defer { importing = false }
        var failures: [String] = []
        for (index, old) in copies.enumerated() {
            if Task.isCancelled { break }
            updateProgress(index + 1, total: copies.count, name: old.filename)
            do {
                var track = try await scanner.rereadCopy(old)
                try Task.checkCancellation()
                var s = snapshot
                guard let i = s.tracks.firstIndex(where: { $0.id == old.id }) else { continue }
                track.favorite = s.tracks[i].favorite
                track.playCount = s.tracks[i].playCount
                track.lastPlayed = s.tracks[i].lastPlayed
                s.tracks[i] = track
                persist(s)
            } catch is CancellationError { break }
            catch { failures.append("\(old.filename)：\(error.localizedDescription)") }
        }
        ArtworkCache.shared.removeAll()
        if !failures.isEmpty { errorMessage = failures.prefix(8).joined(separator: "\n") }
    }

    func startScan(_ id: UUID) { guard !importing else { return }; job = Task { await scanFolder(id); startAlbumLookup() } }
    func startImport(_ urls: [URL]) { guard !importing else { return }; job = Task { await importFiles(urls); startAlbumLookup() } }
    func startAddFolders(_ urls: [URL]) {
        guard !importing else { return }
        job = Task { for url in urls { if Task.isCancelled { break }; await addFolder(url) }; startAlbumLookup() }
    }
    func cancelScan() { job?.cancel(); catalogMigrationJob?.cancel() }

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
        var failures: [String] = [], added = 0, duplicates = 0
        for (i, source) in urls.enumerated() {
            if Task.isCancelled { break }
            updateProgress(i + 1, total: urls.count, name: source.lastPathComponent)
            do {
                let track = try await scanner.importCopy(source)
                let duplicate = tracks.contains { existing in
                    guard existing.available else { return false }
                    if let hash = track.contentHash {
                        let legacyHash = (existing.filename as NSString).deletingPathExtension
                        if existing.contentHash == hash || (existing.folderID == nil && legacyHash == hash) { return true }
                    }
                    return existing.folderID == nil && existing.filename == track.filename
                }
                if duplicate {
                    duplicates += 1
                    if !tracks.contains(where: { $0.folderID == nil && $0.filename == track.filename }) {
                        try? FileManager.default.removeItem(at: root.appendingPathComponent(track.filename))
                    }
                    if let name = track.artworkFilename, !tracks.contains(where: { $0.artworkFilename == name }) {
                        try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
                    }
                } else {
                    var s = snapshot; s.tracks.append(track)
                    if persist(s) { added += 1 }
                    else { try? FileManager.default.removeItem(at: root.appendingPathComponent(track.filename)) }
                }
            } catch is CancellationError { break }
            catch { failures.append("\(source.lastPathComponent)：\(error.localizedDescription)") }
        }
        ArtworkCache.shared.removeAll()
        scanSummary = "导入 \(added) 首歌曲，跳过重复 \(duplicates) 首，失败 \(failures.count) 首"
        if !failures.isEmpty { errorMessage = failures.prefix(8).joined(separator: "\n") }
    }
}

/// Serializes playback.json writes. A newer revision skips an older in-flight
/// checkpoint so a pause cannot be overwritten by a stale 5-second tick.
private final class PlaybackCheckpoint: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lossless.playback-checkpoint")
    private let lock = NSLock()
    private var revision = 0

    func writeNow(_ state: PlaybackState, to url: URL) {
        enqueue(state, to: url, wait: true)
    }

    func writeLater(_ state: PlaybackState, to url: URL) {
        enqueue(state, to: url, wait: false)
    }

    private func enqueue(_ state: PlaybackState, to url: URL, wait: Bool) {
        lock.lock()
        revision += 1
        let revision = revision
        lock.unlock()
        let work = {
            self.lock.lock()
            let latest = self.revision
            self.lock.unlock()
            guard latest == revision else { return }
            try? JSONEncoder().encode(state).write(to: url, options: .atomic)
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }
}
