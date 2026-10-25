import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    @State private var tab = AppTab.library
    @State private var libraryPath = NavigationPath()
    @State private var playlistPath = NavigationPath()
    @State private var favoritesPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var searchFieldFocused = false
    @State private var showPlayer = false
    /// The player overlay stays mounted while a collapse plays (artwork
    /// flight + fade) and unmounts when it lands; see setPlayer(_:).
    @State private var playerMounted = false
    @State private var showSources = false
    @State private var importKind: ImportKind = .files
    @State private var pickerPresented = false
    @State private var query = ""
    @State private var playlistName = ""
    @State private var creatingPlaylist = false
    @State private var playlistBatch: TrackBatch?
    @State private var songPicker: Playlist?
    @State private var pendingDelete: [Track] = []
    @State private var lyricsTrack: Track?
    @State private var renamingPlaylist: Playlist?
    @Namespace private var playerZoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var exportPresented = false
    @State private var exportText = ""
    @State private var exportName = "playlist"
    enum ImportKind { case files, folders, folderPlaylists, playlist }

    /// One spring drives the whole expand/collapse — artwork morph,
    /// library recede and player fade — so the parts never drift apart.
    static let playerSpring: Animation = .spring(response: 0.45, dampingFraction: 0.86)

    var body: some View {
        ZStack {
            playerTabs
                .scaleEffect(reduceMotion ? 1 : (showPlayer ? 0.96 : 1))
                .brightness(reduceMotion ? 0 : (showPlayer ? -0.18 : 0))
                .animation(Self.playerSpring, value: showPlayer)
                .accessibilityHidden(showPlayer)
            if playerMounted {
                NowPlayingView(library: library, player: player, onOpen: open, onDelete: { track in
                    setPlayer(false)
                    pendingDelete = [track]
                }, onClose: { setPlayer(false) }, morphNamespace: playerZoom, morphActive: showPlayer)
                .opacity(showPlayer ? 1 : 0)
                .animation(Self.playerSpring, value: showPlayer)
                .accessibilityHidden(!showPlayer)
                .zIndex(1)
            }
        }
            .sheet(isPresented: $showSources) {
                SourcesView(library: library, player: player)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .fileImporter(isPresented: $pickerPresented, allowedContentTypes: pickerTypes, allowsMultipleSelection: true) { result in
                let kind = importKind
                switch result {
                case .success(let urls):
                    switch kind {
                    case .folders: library.startAddFolders(urls)
                    case .folderPlaylists: library.startFolderPlaylists(urls)
                    case .files: library.startImport(urls)
                    case .playlist: library.startImportPlaylists(urls)
                    }
                case .failure(let error): library.errorMessage = error.localizedDescription
                }
            }
            .fileExporter(isPresented: $exportPresented, document: TextFileDocument(text: exportText),
                contentType: PlaylistFileTypes.m3u8, defaultFilename: exportName) { _ in }
            .alert("重命名歌单", isPresented: Binding(get: { renamingPlaylist != nil }, set: { if !$0 { renamingPlaylist = nil } })) {
                TextField("歌单名称", text: $playlistName)
                Button("保存") {
                    if let renamingPlaylist { library.rename(renamingPlaylist, to: playlistName) }
                    playlistName = ""; self.renamingPlaylist = nil
                }
                Button("取消", role: .cancel) { playlistName = "" }
            }
            .sheet(item: $playlistBatch) { batch in
                AddToPlaylistSheet(library: library, tracks: batch.tracks)
            }
            .sheet(item: $songPicker) { playlist in
                SongPickerSheet(library: library, playlist: playlist)
            }
            .sheet(item: $lyricsTrack) { track in
                LyricsReader(player: player, track: track)
            }
            .alert("新建歌单", isPresented: $creatingPlaylist) {
                TextField("歌单名称", text: $playlistName)
                Button("创建") {
                    _ = library.createPlaylist(playlistName)
                    playlistName = ""
                }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog(RemovalNotice.title(for: pendingDelete), isPresented: Binding(
                get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }
            ), titleVisibility: .visible) {
                if pendingDelete.count == 1, let track = pendingDelete.first {
                    Button(RemovalNotice.deletesAppCopy(track) ? "删除副本" : "从资料库中删除", role: .destructive) {
                        remove(pendingDelete)
                    }
                } else if !pendingDelete.isEmpty {
                    Button("从资料库中删除", role: .destructive) { remove(pendingDelete) }
                }
                Button("取消", role: .cancel) { pendingDelete = [] }
            } message: {
                Text(RemovalNotice.message(for: pendingDelete))
            }
            .alert("无法完成操作", isPresented: Binding(
                get: { !showSources && (library.errorMessage != nil || player.errorMessage != nil) },
                set: { if !$0 { library.errorMessage = nil; player.errorMessage = nil } }
            )) { Button("好") { library.errorMessage = nil; player.errorMessage = nil } }
            message: { Text([library.errorMessage, player.errorMessage].compactMap { $0 }.joined(separator: "\n")) }
    }

    private var miniPlayer: some View {
        MiniPlayer(library: library, player: player, zoom: playerZoom, expanded: showPlayer) { setPlayer(true) }
    }

    @ViewBuilder private var playerTabs: some View {
        if #available(iOS 26.1, *) {
            glassTabs.tabBarMinimizeBehavior(.onScrollDown).tabViewBottomAccessory(isEnabled: player.current != nil) {
                miniPlayer
            }
        } else if #available(iOS 26.0, *) {
            glassTabs.tabBarMinimizeBehavior(.onScrollDown).tabViewBottomAccessory {
                if player.current != nil { miniPlayer }
            }
        } else {
            legacyTabs.safeAreaInset(edge: .bottom, spacing: 0) {
                if player.current != nil {
                    miniPlayer.background(Color(.secondarySystemBackground))
                }
            }
        }
    }

    @available(iOS 26, *)
    private var glassTabs: some View {
        TabView(selection: $tab) {
            Tab("资料库", systemImage: "square.stack", value: AppTab.library) { libraryStack }
            Tab("歌单", systemImage: "music.note.list", value: AppTab.playlists) { playlistStack }
            Tab("收藏", systemImage: "star.fill", value: AppTab.favorites) { favoritesStack }
            Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search, role: .search) { searchStack }
        }
        .searchReselect(title: "搜索") { searchFieldFocused = true }
    }

    private var legacyTabs: some View {
        TabView(selection: $tab) {
            libraryStack.tabItem { Label("资料库", systemImage: "square.stack") }.tag(AppTab.library)
            playlistStack.tabItem { Label("歌单", systemImage: "music.note.list") }.tag(AppTab.playlists)
            favoritesStack.tabItem { Label("收藏", systemImage: "star.fill") }.tag(AppTab.favorites)
            searchStack.tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(AppTab.search)
        }
        .searchReselect(title: "搜索") { searchFieldFocused = true }
    }

    private var libraryStack: some View {
        NavigationStack(path: $libraryPath) {
            libraryHome
                .navigationTitle("资料库")
                .navigationBarTitleDisplayMode(.large)
                .trailingGlass { libraryMore }
                .navigationDestination(for: LibraryRoute.self) { route in destination(route) }
        }
    }

    private var playlistStack: some View {
        NavigationStack(path: $playlistPath) {
            PlaylistHome(library: library, player: player, imports: imports, onOpen: open, onRename: beginRename, onCreate: {
                creatingPlaylist = true
            }, onAddSongs: { songPicker = $0 }, onAddToPlaylist: { playlistBatch = TrackBatch(tracks: $0) })
            .navigationDestination(for: LibraryRoute.self) { route in destination(route) }
        }
    }

    private var favoritesStack: some View {
        NavigationStack(path: $favoritesPath) {
            page(library.favoriteTracks, title: "收藏", kind: .favorites, showsBack: false)
                .navigationDestination(for: LibraryRoute.self) { route in destination(route) }
        }
    }

    private var searchStack: some View {
        NavigationStack(path: $searchPath) {
            searchPage
                .navigationDestination(for: LibraryRoute.self) { route in destination(route) }
        }
    }

    private var searchPage: some View {
        searchResults
            .searchable(text: $query, isPresented: $searchFieldFocused, prompt: "歌曲、艺术家、专辑")
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.large)
            .onChange(of: tab) { _, new in
                if new != .search { searchFieldFocused = false }
            }
    }

    /// Grouped results the way Music presents them — artists, albums, then
    /// songs — instead of one flat song list where albums and artists only
    /// exist implicitly through their songs. An empty query shows the
    /// search prompt, not the whole library.
    @ViewBuilder private var searchResults: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            ContentUnavailableView("搜索你的资料库", systemImage: "magnifyingglass",
                                   description: Text("输入歌曲、艺术家或专辑名称"))
        } else {
            let results = SearchResults.group(tracks: library.tracks, query: query)
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    if !results.artists.isEmpty {
                        Section("艺术家") {
                            ForEach(results.artists, id: \.self) { artist in
                                let tracks = results.songs.filter { $0.artistNames.contains { AudioTags.normalized($0) == AudioTags.normalized(artist) } }
                                browseRow(title: artist, subtitle: "\(tracks.count) 首歌曲", artwork: tracks.first,
                                          groups: collectionGroups(tracks, order: .title)) {
                                    open(.artist(artist))
                                }
                            }
                        }
                    }
                    if !results.albums.isEmpty {
                        Section("专辑") {
                            ForEach(results.albums) { album in
                                browseRow(title: album.name, subtitle: album.artist,
                                          artwork: album.tracks.first { $0.artworkFilename != nil } ?? album.tracks.first,
                                          groups: collectionGroups(album.tracks, artist: artistRoute(for: album))) {
                                    open(.album(album.id))
                                }
                            }
                        }
                    }
                    if !results.songs.isEmpty {
                        Section("歌曲") {
                            ForEach(results.songs) { track in
                                SongContextRow(track: track, root: library.root,
                                               current: player.current?.id == track.id,
                                               playing: player.playing && player.current?.id == track.id,
                                               handlers: searchHandlers(results.songs))
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button("从资料库中删除", role: .destructive) { pendingDelete = [track] }
                                        Button("添加到歌单") { playlistBatch = TrackBatch(tracks: [track]) }.tint(MusicTheme.accent)
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button { library.toggleFavorite(track) } label: {
                                            Label(track.favorite ? "取消收藏" : "收藏", systemImage: "star")
                                        }
                                        .tint(MusicTheme.accent)
                                    }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("search-results")
            }
        }
    }

    private func searchHandlers(_ songs: [Track]) -> SongHandlers {
        SongHandlers(
            play: { player.load($0, context: songs) },
            favorite: { library.toggleFavorite($0) },
            playlist: { playlistBatch = TrackBatch(tracks: [$0]) },
            playNext: { player.enqueue([$0], next: true) },
            addToQueue: { player.enqueue([$0], next: false) },
            album: { open(.album($0.albumID)) },
            artist: { open(.artist($0.primaryArtist)) },
            lyrics: { lyricsTrack = $0 },
            delete: { pendingDelete = [$0] }
        )
    }

    private var libraryMore: some View {
        SectionsMenu(sections: [importMenuGroup(imports)]) {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("更多")
        .modifier(ToolbarChrome())
    }

    private var imports: ImportCommands {
        ImportCommands(
            addFolder: { importKind = .folders; pickerPresented = true },
            addFiles: { importKind = .files; pickerPresented = true },
            newPlaylist: { creatingPlaylist = true },
            importPlaylist: { importKind = .playlist; pickerPresented = true },
            showFolders: { showSources = true },
            folderPlaylists: { importKind = .folderPlaylists; pickerPresented = true }
        )
    }

    private var libraryHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 0) {
                    libraryLink("艺术家", icon: "music.mic", route: .artists)
                    Divider().padding(.leading, 48)
                    libraryLink("专辑", icon: "square.stack", route: .albums)
                    Divider().padding(.leading, 48)
                    libraryLink("歌曲", icon: "music.note", route: .songs)
                    Divider().padding(.leading, 48)
                    libraryLink("最近播放", icon: "clock", route: .recent)
                }
                if library.importing { scanProgress }
                if let summary = library.scanSummary { Text(summary).font(.footnote).foregroundStyle(.secondary) }
                if library.tracks.isEmpty {
                    ContentUnavailableView("你的音乐，随身聆听", systemImage: "music.note.house",
                        description: Text("添加本地音乐文件夹，自动整理专辑、艺术家和歌曲。"))
                    Button { importKind = .folders; pickerPresented = true } label: {
                        Label("添加音乐文件夹", systemImage: "folder.badge.plus").frame(maxWidth: .infinity).padding()
                    }.buttonStyle(.borderedProminent).disabled(library.importing)
                } else {
                    HStack {
                        Text("最近添加").font(.title2.bold())
                        Spacer()
                        Text("\(library.tracks.count) 首").font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 18)], spacing: 24) {
                        ForEach(library.recentAlbums, id: \.id) { album in
                            NavigationLink(value: LibraryRoute.album(album.id)) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ArtworkView(track: album.tracks.first, root: library.root, size: nil).aspectRatio(1, contentMode: .fit)
                                    Text(album.name).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                                    Text(album.artist).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(RowPressStyle())
                            .tint(.primary)
                            .modifier(ActionsContext(
                                sections: collectionGroups(album.tracks, artist: artistRoute(for: album)),
                                preview: MediaPreview(title: album.name, subtitle: album.artist, artwork: album.tracks.first, root: library.root)
                            ))
                        }
                    }
                }
            }.padding(.horizontal, 22).padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .softTopScrollEdge()
        .accessibilityIdentifier("library-home")
    }

    private var pickerTypes: [UTType] {
        switch importKind {
        case .folders, .folderPlaylists: return [.folder]
        case .files: return [.audio]
        case .playlist: return PlaylistFileTypes.readable
        }
    }
    private var scanProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("正在整理音乐").font(.headline); Spacer(); Button("取消") { library.cancelScan() } }
            ProgressView(value: library.progress)
            Text(library.progressText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.padding(.vertical, 8)
    }

    private func libraryLink(_ title: String, icon: String, route: LibraryRoute) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 18) {
                Image(systemName: icon).foregroundStyle(MusicTheme.accent).font(.title2).frame(width: 26)
                Text(title).font(.title3).foregroundStyle(.primary)
                Spacer(); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func destination(_ route: LibraryRoute) -> some View {
        switch route {
        case .songs: page(library.tracks, title: "歌曲", kind: .songs, showsBack: true)
        case .artists: artistIndex
        case .artist(let artist):
            page(library.tracks(forArtist: artist), title: artist, kind: .artist, showsBack: true)
        case .albums: albumIndex
        case .album(let id):
            page(library.tracks.filter { $0.albumID == id }, title: library.tracks.first { $0.albumID == id }?.album ?? "专辑", kind: .album, showsBack: true)
        case .recent: page(library.recentlyPlayed, title: "最近播放", kind: .recent, showsBack: true)
        case .playlist(let id):
            let playlist = library.snapshot.playlists.first { $0.id == id }
            page(library.tracks(for: playlist?.trackIDs ?? []),
                 title: playlist?.name ?? "歌单", kind: .playlist, playlist: playlist, showsBack: true)
        }
    }

    private var artistIndex: some View {
        List(library.artistNames, id: \.self) { artist in
            let tracks = library.tracks(forArtist: artist)
            browseRow(title: artist, subtitle: "\(tracks.count) 首歌曲", artwork: tracks.first, groups: collectionGroups(tracks, order: .title)) {
                open(.artist(artist))
            }
        }
        .listStyle(.plain)
        .navigationTitle("艺术家")
        .navigationBarTitleDisplayMode(.large)
        .trailingGlass { libraryMore }
        .softTopScrollEdge()
    }

    private var albumIndex: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 24) {
                ForEach(library.albumGroups) { album in
                    Button { open(.album(album.id)) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkView(track: album.tracks.first { $0.artworkFilename != nil } ?? album.tracks.first,
                                        root: library.root, size: nil)
                                .aspectRatio(1, contentMode: .fit)
                            Text(album.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                            Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .modifier(ActionsContext(sections: collectionGroups(album.tracks, artist: artistRoute(for: album)),
                        preview: MediaPreview(title: album.name, subtitle: album.artist, artwork: album.tracks.first, root: library.root)))
                }
            }
            .padding(22)
        }
        .accessibilityIdentifier("album-grid")
        .navigationTitle("专辑")
        .navigationBarTitleDisplayMode(.large)
        .trailingGlass { libraryMore }
        .softTopScrollEdge()
    }

    private func browseRow(title: String, subtitle: String, artwork: Track?, artSize: CGFloat = 48, groups: [MenuGroup], openRow: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Button(action: openRow) {
                HStack(spacing: 12) {
                    ArtworkView(track: artwork, root: library.root, size: artSize)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.body).lineLimit(1).foregroundStyle(.primary)
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.vertical, 8)
                .padding(.leading, RowMetrics.leadingInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            SectionsMenu(sections: groups) { EllipsisLabel() }
                .buttonStyle(.borderless)
                .tint(.primary)
                .accessibilityLabel("更多操作")
        }
        .modifier(ActionsContext(sections: groups, preview: MediaPreview(title: title, subtitle: subtitle, artwork: artwork, root: library.root)))
        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
            dimensions[.leading] + RowMetrics.leadingInset + artSize + 12
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private func page(_ tracks: [Track], title: String, kind: CollectionPage.Kind, playlist: Playlist? = nil, showsBack: Bool) -> some View {
        CollectionPage(
            library: library,
            player: player,
            title: title,
            tracks: tracks,
            kind: kind,
            playlist: playlist,
            showsBack: showsBack,
            imports: imports,
            onOpen: open,
            onAddToPlaylist: { playlistBatch = TrackBatch(tracks: $0) },
            onDelete: { pendingDelete = $0 },
            onLyrics: { lyricsTrack = $0 },
            onRename: beginRename,
            onExport: beginExport,
            onAddSongs: { songPicker = $0 },
            onDeletePlaylist: { library.removePlaylist($0) }
        )
    }

    /// Expand/collapse the player overlay with the shared spring. The
    /// view stays mounted while the collapse plays, then unmounts; a
    /// re-open inside that window just flips the state back.
    private func setPlayer(_ expanded: Bool) {
        if expanded { playerMounted = true }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : Self.playerSpring) { showPlayer = expanded }
        if !expanded {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(550))
                if !showPlayer { playerMounted = false }
            }
        }
    }

    private func open(_ route: LibraryRoute) {
        setPlayer(false)
        lyricsTrack = nil
        switch tab {
        case .library: libraryPath.append(route)
        case .playlists: playlistPath.append(route)
        case .favorites: favoritesPath.append(route)
        case .search: searchPath.append(route)
        }
    }

    private func beginRename(_ playlist: Playlist) {
        playlistName = playlist.name
        renamingPlaylist = playlist
    }

    private func beginExport(_ playlist: Playlist, tracks: [Track]) {
        exportText = PlaylistExchange.render(tracks)
        exportName = playlist.name.replacingOccurrences(of: "/", with: "-")
        exportPresented = true
    }

    private func remove(_ tracks: [Track]) {
        for track in tracks {
            player.stopIfCurrent(track)
            library.remove(track)
        }
        pendingDelete = []
    }

    private func artistRoute(for album: AlbumGroup) -> String {
        if album.artist == "合辑" { return album.tracks.first?.artist ?? album.artist }
        return album.artist
    }

    private func collectionGroups(_ tracks: [Track], artist: String? = nil, order: LibrarySort = .album) -> [MenuGroup] {
        let ordered = order.sorted(tracks)
        var go: [MenuAction] = [
            MenuAction(id: "add", title: "添加到歌单", symbol: "text.badge.plus") { playlistBatch = TrackBatch(tracks: ordered) }
        ]
        if let artist {
            go.append(MenuAction(id: "artist", title: "前往艺术家", symbol: "music.mic") { open(.artist(artist)) })
        }
        var groups = [
            MenuGroup(id: "play", entries: [
                MenuAction(id: "play", title: "播放", symbol: "play.fill") { player.play(ordered, shuffled: false) },
                MenuAction(id: "shuffle", title: "随机播放", symbol: "shuffle") { player.play(ordered, shuffled: true) }
            ]),
            MenuGroup(id: "queue", entries: [
                MenuAction(id: "next", title: "下一首播放", symbol: "text.insert") { player.enqueue(ordered, next: true) },
                MenuAction(id: "later", title: "稍后播放", symbol: "text.append") { player.enqueue(ordered, next: false) }
            ]),
            MenuGroup(id: "go", entries: go)
        ]
        if !ordered.isEmpty {
            groups.append(MenuGroup(id: "delete", entries: [
                MenuAction(id: "delete", title: "从资料库中删除", symbol: "trash", role: .destructive) { pendingDelete = ordered }
            ]))
        }
        return groups
    }
}

enum LibraryRoute: Hashable {
    case songs, artists, albums, recent
    case artist(String), album(String), playlist(UUID)
}

private enum AppTab: Hashable {
    case library, playlists, favorites, search
}

/// Search results grouped the way Music presents them: matching artists
/// and albums become their own results (tappable through to their pages),
/// and songs are ranked title match first, then artist, then album, so the
/// thing the user most likely typed is at the top.
struct SearchResults {
    var songs: [Track] = []
    var albums: [AlbumGroup] = []
    var artists: [String] = []
    var isEmpty: Bool { songs.isEmpty && albums.isEmpty && artists.isEmpty }

    static func group(tracks: [Track], query: String) -> SearchResults {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SearchResults() }
        let matched = tracks.filter { $0.matchesSearch(query) }
        func rank(_ track: Track) -> Int {
            if track.title.localizedCaseInsensitiveContains(query) { return 0 }
            if track.artistNames.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return 1 }
            if track.album.localizedCaseInsensitiveContains(query) { return 2 }
            return 3
        }
        let songs = matched.sorted {
            let a = rank($0), b = rank($1)
            if a != b { return a < b }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        let needle = AudioTags.normalized(query)
        let artists = Array(Set(matched.flatMap(\.artistNames).filter { AudioTags.normalized($0).contains(needle) }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return SearchResults(songs: songs, albums: AlbumGroup.groups(matched), artists: artists)
    }
}

struct AlbumGroup: Identifiable {
    var id: String
    var name: String
    var artist: String
    var tracks: [Track]
    /// Most recent `addedAt` in the group, computed once at grouping
    /// time. As a computed property it re-scanned the group's tracks on
    /// every sort comparison of every "recently added" render.
    var latest: Date
    static func groups(_ tracks: [Track]) -> [Self] {
        Dictionary(grouping: tracks, by: \.albumID).map { id, tracks in
            Self(id: id, name: tracks[0].album, artist: tracks[0].albumArtistName, tracks: tracks,
                 latest: tracks.compactMap(\.addedAt).max() ?? .distantPast)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

final class ArtworkCache {
    static let shared = ArtworkCache()
    private let images = NSCache<NSString, UIImage>()
    init() {
        // Thumbnails are small, but an unbounded cache grows with every
        // album ever scrolled past. Cap count and total decoded cost so a
        // large library cannot push the app into memory pressure.
        images.countLimit = 300
        images.totalCostLimit = 64 * 1024 * 1024
    }
    func image(at url: URL) -> UIImage? {
        let key = url.path as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        images.setObject(image, forKey: key, cost: cost)
        return image
    }
    func removeAll() { images.removeAllObjects() }
}

struct ArtworkView: View {
    enum Placeholder { case accent, neutral }
    let track: Track?
    let root: URL
    var size: CGFloat?
    var placeholder: Placeholder = .accent
    var body: some View {
        Group {
            if let name = track?.artworkFilename, let image = ArtworkCache.shared.image(at: root.appendingPathComponent(name)) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if placeholder == .neutral {
                ZStack {
                    Color(white: 0.16)
                    Image(systemName: "music.note").resizable().scaledToFit().padding(30).foregroundStyle(.white.opacity(0.85))
                }
            } else {
                ZStack {
                    LinearGradient(colors: [MusicTheme.accent.opacity(0.85), .pink.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").resizable().scaledToFit().padding(30).foregroundStyle(.white.opacity(0.9))
                }
            }
        }.frame(width: size, height: size).aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: artworkCorner, style: .continuous))
            .accessibilityHidden(true)
    }

    private var artworkCorner: CGFloat {
        let side = size ?? 150
        if side <= 64 { return 6 }
        if side < 120 { return 8 }
        return 12
    }
}

struct MiniPlayer: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    var zoom: Namespace.ID
    var expanded: Bool
    var open: () -> Void
    private var title: String { player.current?.title ?? "未在播放" }
    private var artist: String { player.current?.artist ?? "" }

    var body: some View {
        if #available(iOS 26, *) {
            AccessoryPlacement(title: title, artist: artist, track: player.current, root: library.root, playing: player.playing, toggle: { player.toggle() }, skip: { player.skip() }, open: open, zoom: zoom, expanded: expanded)
        } else {
            AccessoryMiniPlayer(compact: false, title: title, artist: artist, track: player.current, root: library.root, playing: player.playing, toggle: { player.toggle() }, skip: { player.skip() }, open: open, zoom: zoom, expanded: expanded)
        }
    }
}

@available(iOS 26, *)
private struct AccessoryPlacement: View {
    var title: String
    var artist: String
    var track: Track?
    var root: URL
    var playing: Bool
    var toggle: () -> Void
    var skip: () -> Void
    var open: () -> Void
    var zoom: Namespace.ID
    var expanded: Bool
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        AccessoryMiniPlayer(compact: placement == .inline, title: title, artist: artist, track: track, root: root, playing: playing, toggle: toggle, skip: skip, open: open, zoom: zoom, expanded: expanded)
    }
}

private struct AccessoryMiniPlayer: View {
    var compact: Bool
    var title: String
    var artist: String
    var track: Track?
    var root: URL
    var playing: Bool
    var toggle: () -> Void
    var skip: () -> Void
    var open: () -> Void
    var zoom: Namespace.ID
    var expanded: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: track, root: root, size: compact ? 28 : 44)
                // The one shared element of the expand/collapse morph:
                // this thumbnail is the source until the player opens.
                .matchedGeometryEffect(id: "playerArtwork", in: zoom, isSource: !expanded)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !compact, !artist.isEmpty {
                    Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: toggle) {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            .accessibilityLabel(playing ? "暂停" : "播放")
            if !compact {
                Button(action: skip) {
                    Image(systemName: "forward.fill").frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .tint(.primary)
                .accessibilityLabel("下一首")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 0 : 6)
        .frame(maxWidth: .infinity, minHeight: compact ? 36 : 56)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mini-player")
    }
}

// The playerZoom namespace now carries the matched-geometry artwork
// morph (see MiniPlayer and NowPlayingView.ArtworkMorph); the system
// .zoom cover transition and its matchedTransitionSource are gone.

private extension View {
    func searchReselect(title: String, onReselect: @escaping () -> Void) -> some View {
        background { SearchTabReselect(title: title, onReselect: onReselect) }
    }
}

struct TextFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { PlaylistFileTypes.readable }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

func clock(_ seconds: Double) -> String {
    let value = seconds.isFinite ? Int(max(0, seconds)) : 0
    return String(format: "%d:%02d", value / 60, value % 60)
}
