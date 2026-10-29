import SwiftUI

/// Holds a sort permutation so `CollectionPage.body` can re-read fresh track
/// values (favorite, title) without sorting the list again.
private final class TrackOrderMemo {
    var key = 0
    var indices: [Int] = []
}

private struct PlaylistEditing: ViewModifier {
    var enabled: Bool
    var editing: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.environment(\.editMode, .constant(editing ? .active : .inactive))
        } else {
            content
        }
    }
}

struct CollectionPage: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    var title: String
    var tracks: [Track]
    var kind: Kind
    var playlist: Playlist? = nil
    var showsBack = true
    var imports: ImportCommands? = nil
    var onOpen: (LibraryRoute) -> Void
    var onAddToPlaylist: ([Track]) -> Void
    var onDelete: ([Track]) -> Void
    var onLyrics: (Track) -> Void
    var onRename: (Playlist) -> Void = { _ in }
    var onExport: (Playlist, [Track]) -> Void = { _, _ in }
    var onAddSongs: (Playlist) -> Void = { _ in }
    var onDeletePlaylist: (Playlist) -> Void = { _ in }

    enum Kind { case songs, album, artist, recent, favorites, search, playlist }

    @AppStorage("librarySort") private var sortRaw = LibrarySort.title.rawValue
    @AppStorage("albumSort") private var albumSortRaw = LibrarySort.album.rawValue
    @State private var editing = false
    @State private var coverTarget: Playlist?
    @State private var matchingTrack: Track?
    @State private var orderMemo = TrackOrderMemo()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.detailCardHeader) private var detailHeader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let page = songList
            .navigationTitle(kind == .playlist ? "" : title)
            .navigationBarTitleDisplayMode(usesLargeTitle ? .large : .inline)
            .softTopScrollEdge()
            .background {
                if usesArtworkBackground {
                    ArtworkBackground(url: backgroundArtworkURL, followsAppearance: true)
                        .ignoresSafeArea()
                }
            }
            .toolbarBackground(usesArtworkBackground ? .hidden : .automatic, for: .navigationBar)
            .sheet(item: $matchingTrack) { ReleaseMatchingView(library: library, track: $0) }
            .sheet(item: $coverTarget) { PlaylistArtworkEditor(library: library, playlist: $0) }
        if editing {
            page.trailingGlass {
                Button("完成") { editing = false }
                    .font(.body.weight(.semibold))
                    .modifier(ToolbarChrome())
            }
        } else if activeSort != nil {
            page.trailingGlass { sortControl } more: { moreControl }
        } else {
            page.trailingGlass { moreControl }
        }
    }

    private var usesLargeTitle: Bool { kind != .album && kind != .playlist }
    private var usesArtworkBackground: Bool { kind == .album || kind == .playlist }

    private var songList: some View {
        let contextID = playbackContextID
        return List {
            if (kind == .album && !sorted.isEmpty) || playlist != nil { header }
            if kind == .playlist { playlistTransport }
            if showTransport && kind != .playlist {
                PlayShuffleBar(enabled: sorted.contains(where: \.available), play: {
                    player.play(sorted, shuffled: false)
                }, shuffle: {
                    player.play(sorted, shuffled: true)
                })
            }
            ForEach(sorted) { track in
                SongContextRow(
                    track: track,
                    root: library.root,
                    current: player.current?.id == track.id,
                    playing: player.playing && player.current?.id == track.id,
                    indexLabel: kind == .album ? indexLabel(track) : nil,
                    showsMenu: !editing,
                    emphasis: kind == .playlist ? .primary : MusicTheme.accent,
                    showsLocalStatus: kind == .playlist,
                    contextID: contextID,
                    handlers: handlers
                )
                .equatable()
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if let playlist {
                        Button("从歌单中移除", role: .destructive) { library.removeFromPlaylist(track, playlist: playlist) }
                    } else {
                        Button("从资料库中删除", role: .destructive) { onDelete([track]) }
                    }
                    Button("添加到歌单") { onAddToPlaylist([track]) }.tint(MusicTheme.accent)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button { library.toggleFavorite(track) } label: {
                        Label(track.favorite ? "取消收藏" : "收藏", systemImage: "star")
                    }
                    .tint(MusicTheme.accent)
                }
                // Set this at the List row boundary, outside EquatableView
                // and swipe actions, so the system row fill cannot mask the page.
                .listRowBackground(Color.clear)
            }
            .onMove { offsets, destination in
                guard let playlist else { return }
                library.moveTracks(in: playlist, displayed: sorted.map(\.id), from: offsets, to: destination)
            }
            if kind == .playlist && !sorted.isEmpty {
                Text(lengthText(sorted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 12)
            }
            if sorted.isEmpty {
                ContentUnavailableView("还没有歌曲", systemImage: "music.note", description: Text(emptyDescription))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(usesArtworkBackground ? .hidden : .visible)
        .accessibilityIdentifier(kind == .playlist ? "playlist-detail" : kind == .songs ? "songs-list" : "collection-list")
        .modifier(PlaylistEditing(enabled: kind == .playlist, editing: editing))
    }

    private var emptyDescription: String {
        if kind == .playlist { return "使用右上角菜单中的「添加歌曲」。" }
        if kind == .search { return "换一个关键词，或先把音乐加入资料库。" }
        return "从资料库添加音乐。"
    }

    private var showTransport: Bool { !sorted.isEmpty || kind == .playlist || kind == .album }

    @ViewBuilder private var header: some View {
        if kind == .album, let first = sorted.first {
            VStack(spacing: 14) {
                ArtworkView(track: sorted.first { $0.artworkFilename != nil } ?? first, root: library.root, size: 250)
                    .modifier(DetailHeaderArtwork())
                    .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
                    .compositingGroup()
                    .padding(.top, 8)
                Text(first.album).font(.title.bold()).multilineTextAlignment(.center)
                Button { onOpen(.artist(albumArtistRoute)) } label: {
                    Text(first.albumArtistName).font(.title3).foregroundStyle(MusicTheme.accent)
                }
                .buttonStyle(.plain)
                Text(lengthText(sorted)).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
        } else if let playlist {
            VStack(spacing: 0) {
                PlaylistCover(playlist: playlist, library: library)
                    .frame(maxWidth: 300)
                    .containerRelativeFrame(.horizontal) { width, _ in min(300, width * 0.65) }
                    .modifier(DetailHeaderArtwork())
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                Text(playlist.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("本地歌单 · \(sorted.count) 首歌曲")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 20))
        }
    }

    private var coverTrack: Track? {
        if let playlist { return library.coverTrack(for: playlist) }
        if kind == .album { return sorted.first { $0.artworkFilename != nil } ?? sorted.first }
        return nil
    }

    private var backgroundArtworkURL: URL? {
        let filename = playlist?.customArtworkFilename ?? coverTrack?.artworkFilename
        return filename.map { library.root.appendingPathComponent($0) }
    }

    private var playlistTransport: some View {
        HStack(spacing: 14) {
            Button { player.play(sorted, shuffled: true) } label: {
                Image(systemName: "shuffle")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .background(Color.primary.opacity(0.1), in: Circle())
            }
            .disabled(!sorted.contains(where: \.available))
            .accessibilityLabel("随机播放")
            Button { player.play(sorted, shuffled: false) } label: {
                Label("播放", systemImage: "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .background(Color.primary, in: Capsule())
            }
            .disabled(!sorted.contains(where: \.available))
            .accessibilityLabel("播放歌单")
            Button {
                if let playlist { onAddSongs(playlist) }
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.medium))
                    .frame(width: 48, height: 48)
                    .background(Color.primary.opacity(0.1), in: Circle())
            }
            .accessibilityLabel("添加歌曲")
        }
        .foregroundStyle(.primary)
        .buttonStyle(PressScaleStyle())
        .listRowInsets(EdgeInsets(top: 0, leading: 52, bottom: 22, trailing: 52))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("playlist-transport")
        // Adding songs remains available even in an empty playlist.
        .disabled(editing)
    }

    private var albumArtistRoute: String {
        let name = sorted.first?.albumArtistName ?? title
        if name == "合辑" { return sorted.first?.artist ?? name }
        return name
    }

    private func lengthText(_ tracks: [Track]) -> String {
        let minutes = Int((tracks.reduce(0) { $0 + max(0, $1.duration.isFinite ? $1.duration : 0) } / 60).rounded())
        if minutes <= 0 { return "\(tracks.count) 首歌曲" }
        return "\(tracks.count) 首歌曲 · \(minutes) 分钟"
    }

    private func indexLabel(_ track: Track) -> String? {
        guard let number = track.trackNumber else { return nil }
        if let disc = track.discNumber, disc > 0 { return "\(disc)-\(number)" }
        return "\(number)"
    }

    private var activeSort: LibrarySort? {
        switch kind {
        case .recent, .playlist: return nil
        case .album: return LibrarySort(rawValue: albumSortRaw) ?? .album
        default: return LibrarySort(rawValue: sortRaw) ?? .title
        }
    }

    private var sortOptions: [LibrarySort] {
        LibrarySort.allCases.filter { kind == .album || $0 != .album }
    }

    /// Sort key for the memo. Hashing the fields that affect order is much
    /// cheaper than `localizedStandardCompare` on every play/pause refresh.
    private var orderKey: Int {
        var hasher = Hasher()
        hasher.combine(activeSort?.rawValue)
        for track in tracks {
            hasher.combine(track.id)
            hasher.combine(track.title)
            hasher.combine(track.artist)
            hasher.combine(track.addedAt?.timeIntervalSinceReferenceDate)
            hasher.combine(track.playCount)
            hasher.combine(track.discNumber)
            hasher.combine(track.trackNumber)
            hasher.combine(track.filename)
        }
        return hasher.finalize()
    }

    private var sorted: [Track] {
        if tracks.isEmpty { return tracks }
        let key = orderKey
        if orderMemo.key != key || orderMemo.indices.count != tracks.count {
            let ordered = activeSort?.sorted(tracks) ?? tracks
            var positions: [UUID: Int] = [:]
            positions.reserveCapacity(tracks.count)
            for (index, track) in tracks.enumerated() where positions[track.id] == nil {
                positions[track.id] = index
            }
            orderMemo.indices = ordered.map { positions[$0.id] ?? 0 }
            orderMemo.key = key
        }
        return orderMemo.indices.map { tracks[$0] }
    }

    private var playbackContextID: Int { trackContextID(sorted) }

    private var sortControl: some View {
        Menu {
            if let activeSort {
                ForEach(sortOptions) { item in
                    Button {
                        if kind == .album { albumSortRaw = item.rawValue } else { sortRaw = item.rawValue }
                    } label: {
                        if item == activeSort { Label(item.label, systemImage: "checkmark") } else { Text(item.label) }
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("排序")
        .modifier(ToolbarChrome())
    }

    private var moreControl: some View {
        SectionsMenu(sections: moreGroups) {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("更多")
        .modifier(ToolbarChrome())
    }

    private var moreGroups: [MenuGroup] {
        if let playlist {
            return [
                MenuGroup(id: "edit", entries: [
                    MenuAction(id: "add", title: "添加歌曲", symbol: "plus") { onAddSongs(playlist) },
                    MenuAction(id: "edit", title: "编辑", symbol: "pencil") { editing = true },
                    MenuAction(id: "rename", title: "重命名", symbol: "pencil") { onRename(playlist) },
                    MenuAction(id: "cover", title: "修改封面", symbol: "photo") { coverTarget = playlist },
                    MenuAction(id: "export", title: "导出播放列表", symbol: "square.and.arrow.up") { onExport(playlist, sorted) }
                ]),
                MenuGroup(id: "delete", entries: [
                    MenuAction(id: "delete", title: "删除歌单", symbol: "trash", role: .destructive) {
                        onDeletePlaylist(playlist)
                        if let close = detailHeader.close { close() } else { dismiss() }
                    }
                ])
            ]
        }
        if kind == .album {
            return [
                MenuGroup(id: "go", entries: [
                    MenuAction(id: "add", title: "添加到歌单", symbol: "text.badge.plus") { onAddToPlaylist(sorted) },
                    MenuAction(id: "artist", title: "前往艺术家", symbol: "music.mic") { onOpen(.artist(albumArtistRoute)) }
                ]),
                MenuGroup(id: "delete", entries: [
                    MenuAction(id: "delete", title: "从资料库中删除", symbol: "trash", role: .destructive) { onDelete(sorted) }
                ])
            ]
        }
        if kind == .artist {
            return [
                MenuGroup(id: "add", entries: [
                    MenuAction(id: "add", title: "添加到歌单", symbol: "text.badge.plus") { onAddToPlaylist(sorted) }
                ]),
                MenuGroup(id: "delete", entries: [
                    MenuAction(id: "delete", title: "从资料库中删除", symbol: "trash", role: .destructive) { onDelete(sorted) }
                ])
            ]
        }
        if let imports { return [importMenuGroup(imports)] }
        return []
    }

    private var handlers: SongHandlers {
        SongHandlers(
            play: { player.load($0, context: sorted) },
            favorite: { library.toggleFavorite($0) },
            playlist: { onAddToPlaylist([$0]) },
            playNext: { player.enqueue([$0], next: true) },
            addToQueue: { player.enqueue([$0], next: false) },
            album: { onOpen(.album($0.albumID)) },
            artist: { onOpen(.artist($0.primaryArtist)) },
            lyrics: onLyrics,
            delete: { onDelete([$0]) },
            removeFromPlaylist: playlist.map { list in { track in library.removeFromPlaylist(track, playlist: list) } },
            setCover: playlist.map { list in { track in library.setCover(track, for: list) } },
            identify: { matchingTrack = $0 }
        )
    }
}
