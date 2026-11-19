import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    @State private var nav = LibraryNavigation()
    @State private var commands = LibraryCommands()
    /// UIKit owns the player presentation (full screen, zooming from the
    /// mini). `playerSettled` tells accessibility the zoom has finished.
    @State private var showPlayer = false
    @State private var playerSettled = false
    @State private var playerZoom = PlayerZoomAnchor()
    @State private var showSources = false
    @State private var importKind: ImportKind = .files
    @State private var pickerPresented = false
    @State private var playlistName = ""
    @State private var creatingPlaylist = false
    @State private var playlistBatch: TrackBatch?
    @State private var songPicker: Playlist?
    @State private var pendingDelete: [Track] = []
    @State private var lyricsTrack: Track?
    @State private var matchingTrack: Track?
    @State private var batchFill = false
    @State private var renamingPlaylist: Playlist?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var exportPresented = false
    @State private var exportText = ""
    @State private var exportName = "playlist"
    enum ImportKind { case files, folders, folderPlaylists, playlist }

    var body: some View {
        let _ = commands.update(actions: actions, openPlayer: { showPlayer = true })
        LibraryTabs(library: library, player: player, nav: nav, commands: commands,
                    hasCurrent: player.current != nil, zoom: playerZoom)
            .background {
                PlayerPresentation(isPresented: $showPlayer, anchor: playerZoom,
                                   onSettled: { playerSettled = true }) {
                    NowPlayingView(library: library, player: player, onOpen: open, onDelete: { track in
                        showPlayer = false
                        pendingDelete = [track]
                    }, onClose: { showPlayer = false }, presentationSettled: playerSettled)
                    .background { NowPlayingBackground(library: library, player: player).ignoresSafeArea() }
                    .environment(\.colorScheme, .dark)
                }
            }
            .onChange(of: showPlayer) { _, shown in if !shown { playerSettled = false } }
            .onChange(of: player.current?.id) { _, currentID in
                if currentID == nil { showPlayer = false }
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
            .sheet(item: $matchingTrack) { ReleaseMatchingView(library: library, track: $0) }
            .sheet(isPresented: $batchFill) { BatchFillView(library: library) }
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
            .overlay(alignment: .top) {
                ZStack {
                    if let progress = library.coverProgress {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(progress.total == 1 ? "\(progress.label)…" : "\(progress.label) \(progress.done + 1)/\(progress.total)")
                                .font(.subheadline).monospacedDigit()
                            if progress.total > 1 {
                                Button("停止") { library.stopCoverUpdate() }.font(.subheadline.weight(.semibold))
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.opacity)
                        .accessibilityIdentifier("cover-updating")
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: library.coverProgress == nil)
            }
            .alert(library.coverReport?.title ?? "更新封面", isPresented: Binding(
                get: { !showSources && library.coverReport?.items.count == 1 },
                set: { if !$0 { library.coverReport = nil } }
            )) { Button("好") { library.coverReport = nil } }
            message: { Text(library.coverReport?.items.first?.result.message ?? "") }
            .sheet(isPresented: Binding(
                get: { !showSources && (library.coverReport?.items.count ?? 0) > 1 },
                set: { if !$0 { library.coverReport = nil } }
            )) {
                if let report = library.coverReport { CoverReportSheet(report: report) }
            }
    }

    private var actions: LibraryActions {
        LibraryActions(
            open: open,
            imports: imports,
            addToPlaylist: { playlistBatch = TrackBatch(tracks: $0) },
            delete: { pendingDelete = $0 },
            lyrics: { lyricsTrack = $0 },
            identify: { matchingTrack = $0 },
            rename: beginRename,
            export: beginExport,
            addSongs: { songPicker = $0 },
            createPlaylist: { creatingPlaylist = true },
            batchFill: { batchFill = true }
        )
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

    private var pickerTypes: [UTType] {
        switch importKind {
        case .folders, .folderPlaylists: return [.folder]
        case .files: return [.audio]
        case .playlist: return PlaylistFileTypes.readable
        }
    }

    private func open(_ route: LibraryRoute) {
        showPlayer = false
        lyricsTrack = nil
        nav.open(route)
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
}

/// Tab selection, navigation paths and browse queries. Observable, so each
/// tab reads only its own path and query.
@Observable private final class LibraryNavigation {
    var tab = AppTab.library
    var libraryPath = NavigationPath()
    var playlistPath = NavigationPath()
    var favoritesPath = NavigationPath()
    var searchPath = NavigationPath()
    var query = ""
    var artistQuery = ""
    var albumQuery = ""
    var searchFieldFocused = false

    func open(_ route: LibraryRoute) {
        switch tab {
        case .library: libraryPath.append(route)
        case .playlists: playlistPath.append(route)
        case .favorites: favoritesPath.append(route)
        case .search: searchPath.append(route)
        }
    }
}

/// The shell's closures behind one stable reference. Closures made in the
/// root body are new values on every evaluation, and handing them to
/// LibraryTabs made SwiftUI treat it as changed and re-run its body. Each
/// root evaluation refreshes them here, where LibraryTabs does not compare.
private final class LibraryCommands {
    var actions = LibraryActions.none
    var openPlayer: () -> Void = {}

    func update(actions: LibraryActions, openPlayer: @escaping () -> Void) {
        self.actions = actions
        self.openPlayer = openPlayer
    }
}

/// What browse pages ask of the shell: navigation that also closes the
/// player, and the sheets, alerts and pickers the shell presents.
private struct LibraryActions {
    var open: (LibraryRoute) -> Void
    var imports: ImportCommands
    var addToPlaylist: ([Track]) -> Void
    var delete: ([Track]) -> Void
    var lyrics: (Track) -> Void
    var identify: (Track) -> Void
    var rename: (Playlist) -> Void
    var export: (Playlist, [Track]) -> Void
    var addSongs: (Playlist) -> Void
    var createPlaylist: () -> Void
    var batchFill: () -> Void

    static let none = LibraryActions(open: { _ in }, imports: ImportCommands(addFolder: {}, addFiles: {}, newPlaylist: {},
        importPlaylist: {}, showFolders: {}, folderPlaylists: {}), addToPlaylist: { _ in }, delete: { _ in },
        lyrics: { _ in }, identify: { _ in }, rename: { _ in }, export: { _, _ in }, addSongs: { _ in },
        createPlaylist: {}, batchFill: {})
}

/// Applies the TabView and the native bottom accessory. The accessory
/// replaces its mini whenever this body runs, and a tap landing during the
/// replacement is lost. So it holds only references and the flag that
/// changes the accessory, and re-runs only when it changes; the tabs
/// and the mini observe the stores themselves.
private struct LibraryTabs: View {
    let library: LibraryStore
    let player: PlayerStore
    @Bindable var nav: LibraryNavigation
    let commands: LibraryCommands
    var hasCurrent: Bool
    let zoom: PlayerZoomAnchor

    @ViewBuilder var body: some View {
        if #available(iOS 26.1, *) {
            glassTabs.tabBarMinimizeBehavior(.onScrollDown).tabViewBottomAccessory(isEnabled: hasCurrent) {
                miniPlayer
            }
        } else if #available(iOS 26.0, *) {
            glassTabs.tabBarMinimizeBehavior(.onScrollDown).tabViewBottomAccessory {
                if hasCurrent { miniPlayer }
            }
        } else {
            legacyTabs.safeAreaInset(edge: .bottom, spacing: 0) {
                if hasCurrent {
                    miniPlayer.background(PlayerZoomSource(anchor: zoom))
                }
            }
        }
    }

    /// The native accessory owns the resting mini and its scroll animation; it
    /// is also the source of the system zoom into the player (see
    /// `PlayerZoomAnchor`).
    private var miniPlayer: some View {
        AccessoryMini(library: library, player: player, open: { [commands] in commands.openPlayer() })
    }

    @available(iOS 26, *)
    private var glassTabs: some View {
        TabView(selection: $nav.tab) {
            Tab("资料库", systemImage: "square.stack", value: AppTab.library) { browser(.library) }
            Tab("歌单", systemImage: "music.note.list", value: AppTab.playlists) { browser(.playlists) }
            Tab("收藏", systemImage: "star.fill", value: AppTab.favorites) { browser(.favorites) }
            Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search) { browser(.search) }
        }
        .searchReselect(title: "搜索") { nav.searchFieldFocused = true }
        .tabReselect(title: "歌单") { returnToPlaylistHome() }
    }

    private var legacyTabs: some View {
        TabView(selection: $nav.tab) {
            browser(.library).tabItem { Label("资料库", systemImage: "square.stack") }.tag(AppTab.library)
            browser(.playlists).tabItem { Label("歌单", systemImage: "music.note.list") }.tag(AppTab.playlists)
            browser(.favorites).tabItem { Label("收藏", systemImage: "star.fill") }.tag(AppTab.favorites)
            browser(.search).tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(AppTab.search)
        }
        .searchReselect(title: "搜索") { nav.searchFieldFocused = true }
        .tabReselect(title: "歌单") { returnToPlaylistHome() }
    }

    private func browser(_ root: AppTab) -> some View {
        LibraryBrowser(library: library, player: player, nav: nav, actions: commands.actions, root: root)
    }

    /// Second tap on the playlist tab. Already at the home does nothing.
    /// Every pushed page, including album and playlist detail, pops to the root.
    private func returnToPlaylistHome() {
        switch PlaylistTabNavigation.step(pathIsEmpty: nav.playlistPath.isEmpty) {
        case .stay:
            break
        case .popPath:
            var transaction = Transaction()
            transaction.disablesAnimations = false
            withTransaction(transaction) {
                nav.playlistPath = NavigationPath()
            }
        }
    }
}

/// Bytes between `LibraryTabs`' stored fields that belong to no field. For
/// tests: SwiftUI compares the shell's stored bytes, and these hold leftover
/// data, so any gap can make an update that changed nothing re-run the shell
/// and replace the mini.
@MainActor enum LibraryTabsLayout {
    static func gapBytes(library: LibraryStore, player: PlayerStore) -> Int {
        let tabs = LibraryTabs(library: library, player: player, nav: LibraryNavigation(),
                               commands: LibraryCommands(), hasCurrent: true, zoom: PlayerZoomAnchor())
        let used = Mirror(reflecting: tabs).children.reduce(0) { total, field in
            total + _openExistential(type(of: field.value), do: size)
        }
        return MemoryLayout<LibraryTabs>.size - used
    }

    private static func size<T>(_: T.Type) -> Int { MemoryLayout<T>.size }
}

/// The native accessory's mini. It observes the stores itself, so playback
/// changes update it in place instead of re-running `LibraryTabs`.
private struct AccessoryMini: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    var open: () -> Void
    @State private var instance = UUID()

    var body: some View {
        PlayerMiniSlotView { compact in
            MiniPlayer(library: library, player: player, compact: compact, open: open)
        }
        .onAppear { MiniAccessoryProbe.appeared(instance, for: player) }
        .onChange(of: player.current?.id, initial: true) { _, id in MiniAccessoryProbe.showed(id, for: player) }
    }
}

/// One tab's navigation stack and the browse pages pushed onto it.
private struct LibraryBrowser: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    @Bindable var nav: LibraryNavigation
    let actions: LibraryActions
    let root: AppTab
    @Namespace private var zoom

    @ViewBuilder var body: some View {
        switch root {
        case .library: libraryStack
        case .playlists: playlistStack
        case .favorites: favoritesStack
        case .search: searchStack
        }
    }

    private var libraryStack: some View {
        NavigationStack(path: $nav.libraryPath) {
            libraryHome
                .navigationTitle("资料库")
                .navigationBarTitleDisplayMode(.large)
                .trailingGlass { libraryMore }
                .navigationDestination(for: LibraryRoute.self) { route in destination(route) }
                .navigationDestination(for: DetailZoomRoute.self) { detail in
                    destination(detail.route)
                        .modifier(DetailZoomDestination(id: detail, namespace: zoom))
                }
        }
        .environment(\.detailZoomNamespace, zoom)
    }

    private var playlistStack: some View {
        NavigationStack(path: $nav.playlistPath) {
            PlaylistHome(library: library, player: player, imports: actions.imports, onOpen: actions.open, onRename: actions.rename, onCreate: {
                actions.createPlaylist()
            }, onAddSongs: { actions.addSongs($0) }, onAddToPlaylist: { actions.addToPlaylist($0) })
            .navigationDestination(for: LibraryRoute.self) { route in destination(route) }
            .navigationDestination(for: DetailZoomRoute.self) { detail in
                destination(detail.route)
                    .modifier(DetailZoomDestination(id: detail, namespace: zoom))
            }
        }
        .environment(\.detailZoomNamespace, zoom)
    }

    private var favoritesStack: some View {
        NavigationStack(path: $nav.favoritesPath) {
            page(library.favoriteTracks, title: "收藏", kind: .favorites, showsBack: false)
                .navigationDestination(for: LibraryRoute.self) { route in destination(route) }
                .navigationDestination(for: DetailZoomRoute.self) { detail in
                    destination(detail.route)
                        .modifier(DetailZoomDestination(id: detail, namespace: zoom))
                }
        }
        .environment(\.detailZoomNamespace, zoom)
    }

    private var searchStack: some View {
        NavigationStack(path: $nav.searchPath) {
            searchPage
                .navigationDestination(for: LibraryRoute.self) { route in destination(route) }
                .navigationDestination(for: DetailZoomRoute.self) { detail in
                    destination(detail.route)
                        .modifier(DetailZoomDestination(id: detail, namespace: zoom))
                }
        }
        .environment(\.detailZoomNamespace, zoom)
    }

    private var searchPage: some View {
        searchResults
            .searchable(text: $nav.query, isPresented: $nav.searchFieldFocused, prompt: "歌曲、艺术家、专辑、歌单")
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.large)
            .onChange(of: nav.tab) { _, new in
                if new != .search { nav.searchFieldFocused = false }
            }
    }

    /// Grouped results the way Music presents them — artists, albums, then
    /// songs — instead of one flat song list where albums and artists only
    /// exist implicitly through their songs. An empty query shows the
    /// search prompt, not the whole library.
    @ViewBuilder private var searchResults: some View {
        let trimmed = nav.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            ContentUnavailableView("搜索你的资料库", systemImage: "magnifyingglass",
                                   description: Text("输入歌曲、艺术家、专辑或歌单名称"))
        } else {
            let results = library.searchResults(matching: trimmed)
            if results.isEmpty {
                ContentUnavailableView.search(text: nav.query)
            } else {
                let songContext = trackContextID(results.songs)
                List {
                    if !results.artists.isEmpty {
                        Section("艺术家") {
                            ForEach(results.artists, id: \.self) { artist in
                                let tracks = results.tracksByArtist[artist] ?? []
                                browseRow(title: artist, subtitle: "\(tracks.count) 首歌曲", artwork: tracks.first,
                                          groups: collectionGroups(tracks, order: .title)) {
                                    actions.open(.artist(artist))
                                }
                            }
                        }
                    }
                    if !results.albums.isEmpty {
                        Section("专辑") {
                            ForEach(results.albums) { album in
                                browseRow(title: album.name, subtitle: album.artist,
                                          artwork: album.tracks.first { $0.artworkFilename != nil } ?? album.tracks.first,
                                          groups: collectionGroups(album.tracks, artist: artistRoute(for: album), cover: LibraryStore.coverTarget(album.tracks))) {
                                    actions.open(.album(album.id))
                                }
                            }
                        }
                    }
                    if !results.playlists.isEmpty {
                        Section("歌单") {
                            ForEach(results.playlists) { playlist in
                                Button { actions.open(.playlist(playlist.id)) } label: {
                                    HStack(spacing: 12) {
                                        PlaylistCover(playlist: playlist, library: library)
                                            .frame(width: 48, height: 48)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(playlist.name).foregroundStyle(.primary)
                                            Text("\(playlist.trackIDs.count) 首歌曲")
                                                .font(.subheadline).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(RowPressStyle())
                                .accessibilityIdentifier("search-playlist-\(playlist.id)")
                            }
                        }
                    }
                    if !results.songs.isEmpty {
                        Section("歌曲") {
                            ForEach(results.songs) { track in
                                SongContextRow(track: track, root: library.root,
                                               current: player.current?.id == track.id,
                                               playing: player.playing && player.current?.id == track.id,
                                               contextID: songContext,
                                               handlers: searchHandlers(results.songs))
                                    .equatable()
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button("从资料库中删除", role: .destructive) { actions.delete([track]) }
                                        Button("添加到歌单") { actions.addToPlaylist([track]) }.tint(MusicTheme.accent)
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button { library.toggleFavorite(track) } label: {
                                            Label(track.favorite ? "取消收藏" : "收藏", systemImage: "star")
                                        }
                                        .tint(MusicTheme.accent)
                                    }
                                    // Apply List traits outside EquatableView and swipe actions.
                                    .listRowInsets(EdgeInsets())
                                    .listRowBackground(Color.clear)
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
            playlist: { actions.addToPlaylist([$0]) },
            playNext: { player.enqueue([$0], next: true) },
            addToQueue: { player.enqueue([$0], next: false) },
            album: { actions.open(.album($0.albumID)) },
            artist: { actions.open(.artist($0.primaryArtist)) },
            lyrics: { actions.lyrics($0) },
            delete: { actions.delete([$0]) },
            identify: { actions.identify($0) },
            updateCover: { library.startCoverUpdate([$0]) }
        )
    }

    private var libraryMore: some View {
        SectionsMenu(sections: [importMenuGroup(actions.imports)] + coverMenuGroup) {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("更多")
        .modifier(ToolbarChrome())
    }

    /// 更新缺失封面 while some song still shows the placeholder, and a checked
    /// batch for songs that are also missing an album name.
    private var coverMenuGroup: [MenuGroup] {
        var entries: [MenuAction] = []
        let missing = library.tracks.filter { $0.available && $0.artworkFilename == nil }.count
        if missing > 0 {
            entries.append(MenuAction(id: "update-covers", title: "更新缺失封面（\(missing) 首）", symbol: "photo.badge.arrow.down") {
                library.startCoverUpdate(library.coverTargets)
            })
        }
        let batch = library.batchFillTargets.count
        if batch > 0 {
            entries.append(MenuAction(id: "batch-fill", title: "勾选补全（\(batch) 首）", symbol: "checklist") {
                actions.batchFill()
            })
        }
        return entries.isEmpty ? [] : [MenuGroup(id: "covers", entries: entries)]
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
                    Button { actions.imports.addFolder() } label: {
                        Label("添加音乐文件夹", systemImage: "folder.badge.plus").frame(maxWidth: .infinity).padding()
                    }.buttonStyle(.borderedProminent).disabled(library.importing)
                } else {
                    HStack {
                        Text("最近添加").font(.title2.bold())
                        Spacer()
                        Text("\(library.recentAlbums.count) 张专辑").font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 18)], spacing: 24) {
                        ForEach(library.recentAlbums, id: \.id) { album in
                            DetailZoomLink(route: .album(album.id), grid: .recentAlbums) {
                                ArtworkView(track: album.tracks.first { $0.artworkFilename != nil } ?? album.tracks.first,
                                            root: library.root, size: nil).aspectRatio(1, contentMode: .fit)
                            } label: { artwork in
                                VStack(alignment: .leading, spacing: 8) {
                                    artwork
                                    Text(album.name).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                                    Text(album.artist).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(RowPressStyle())
                            .tint(.primary)
                            .modifier(ActionsContext(
                                sections: collectionGroups(album.tracks, artist: artistRoute(for: album), cover: LibraryStore.coverTarget(album.tracks)),
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
            page(library.tracks.filter { $0.albumID == id }, title: library.tracks.first { $0.albumID == id }?.albumTitle ?? "专辑", kind: .album, showsBack: true)
        case .recent: page(library.recentlyPlayed, title: "最近播放", kind: .recent, showsBack: true)
        case .playlist(let id):
            let playlist = library.snapshot.playlists.first { $0.id == id }
            page(library.tracks(for: playlist?.trackIDs ?? []),
                 title: playlist?.name ?? "歌单", kind: .playlist, playlist: playlist, showsBack: true)
        }
    }

    private var artistIndex: some View {
        let search = LibrarySearchQuery(nav.artistQuery)
        let artists = library.artistNames.filter { search.matches($0) }
        return List(artists, id: \.self) { artist in
            let tracks = library.tracks(forArtist: artist)
            browseRow(title: artist, subtitle: "\(tracks.count) 首歌曲", artwork: tracks.first, groups: collectionGroups(tracks, order: .title)) {
                actions.open(.artist(artist))
            }
        }
        .listStyle(.plain)
        .searchable(text: $nav.artistQuery, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索艺术家")
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if artists.isEmpty && !search.isEmpty { ContentUnavailableView.search(text: nav.artistQuery) }
        }
        .navigationTitle("艺术家")
        .navigationBarTitleDisplayMode(.large)
        .trailingGlass { libraryMore }
        .softTopScrollEdge()
    }

    private var albumIndex: some View {
        let search = LibrarySearchQuery(nav.albumQuery)
        let albums = library.albumGroups.filter { search.matches([$0.name, $0.artist]) }
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 24) {
                ForEach(albums) { album in
                    DetailZoomLink(route: .album(album.id), grid: .albumIndex) {
                        ArtworkView(track: album.tracks.first { $0.artworkFilename != nil } ?? album.tracks.first,
                                    root: library.root, size: nil).aspectRatio(1, contentMode: .fit)
                    } label: { artwork in
                        VStack(alignment: .leading, spacing: 6) {
                            artwork
                            Text(album.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                            Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("album-card-\(album.id)")
                    .modifier(ActionsContext(sections: collectionGroups(album.tracks, artist: artistRoute(for: album), cover: LibraryStore.coverTarget(album.tracks)),
                        preview: MediaPreview(title: album.name, subtitle: album.artist, artwork: album.tracks.first, root: library.root)))
                }
            }
            .padding(22)
        }
        .accessibilityIdentifier("album-grid")
        .searchable(text: $nav.albumQuery, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索专辑、艺术家")
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if albums.isEmpty && !search.isEmpty { ContentUnavailableView.search(text: nav.albumQuery) }
        }
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
            imports: actions.imports,
            onOpen: actions.open,
            onAddToPlaylist: { actions.addToPlaylist($0) },
            onDelete: { actions.delete($0) },
            onLyrics: { actions.lyrics($0) },
            onRename: actions.rename,
            onExport: actions.export,
            onAddSongs: { actions.addSongs($0) },
            onDeletePlaylist: { library.removePlaylist($0) }
        )
    }

    private func artistRoute(for album: AlbumGroup) -> String {
        if album.artist == "合辑" { return album.tracks.first?.artist ?? album.artist }
        return album.artist
    }

    private func collectionGroups(_ tracks: [Track], artist: String? = nil, cover: Track? = nil,
                                  order: LibrarySort = .album) -> [MenuGroup] {
        let ordered = order.sorted(tracks)
        var go: [MenuAction] = [
            MenuAction(id: "add", title: "添加到歌单", symbol: "text.badge.plus") { actions.addToPlaylist(ordered) }
        ]
        if let artist {
            go.append(MenuAction(id: "artist", title: "前往艺术家", symbol: "music.mic") { actions.open(.artist(artist)) })
        }
        if let cover {
            go.append(MenuAction(id: "update-cover", title: "更新封面", symbol: "photo.badge.arrow.down") {
                library.startCoverUpdate([cover])
            })
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
                MenuAction(id: "delete", title: "从资料库中删除", symbol: "trash", role: .destructive) { actions.delete(ordered) }
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
    var playlists: [Playlist] = []
    /// Songs for each displayed artist, keyed by the artist string. Built once
    /// per query so a row does not scan the song list and re-normalize names.
    var tracksByArtist: [String: [Track]] = [:]
    var isEmpty: Bool { songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }

    static func group(tracks: [Track], playlists: [Playlist] = [], query: String) -> SearchResults {
        let search = LibrarySearchQuery(query)
        guard !search.isEmpty else { return SearchResults() }
        let matched = tracks.filter { $0.matchesSearch(search) }
        func rank(_ track: Track) -> Int {
            if search.matches(track.title) { return 0 }
            if search.matches(track.artistNames) { return 1 }
            if search.matches(track.albumTitle) { return 2 }
            return 3
        }
        let songs = matched.sorted {
            let a = rank($0), b = rank($1)
            if a != b { return a < b }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        let artists = Array(Set(matched.flatMap(\.artistNames).filter { search.matches($0) }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var byNorm: [String: [Track]] = [:]
        for song in songs {
            var seen = Set<String>()
            for name in song.artistNames {
                let key = AudioTags.normalized(name)
                if seen.insert(key).inserted { byNorm[key, default: []].append(song) }
            }
        }
        var tracksByArtist: [String: [Track]] = [:]
        for artist in artists { tracksByArtist[artist] = byNorm[AudioTags.normalized(artist)] ?? [] }
        let matchingPlaylists = playlists.filter { search.matches($0.name) }
        return SearchResults(songs: songs, albums: AlbumGroup.groups(matched), artists: artists,
                             playlists: matchingPlaylists, tracksByArtist: tracksByArtist)
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
            Self(id: id, name: tracks[0].albumTitle, artist: tracks[0].albumArtistName, tracks: tracks,
                 latest: tracks.compactMap(\.addedAt).max() ?? .distantPast)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct MiniPlayer: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    var compact: Bool
    var open: () -> Void
    private var title: String { player.current?.title ?? "未在播放" }
    private var artist: String { player.current?.artist ?? "" }

    var body: some View {
        AccessoryMiniPlayer(compact: compact, title: title, artist: artist, track: player.current,
                            root: library.root, playing: player.playing, toggle: { player.toggle() },
                            skip: { player.skip() }, open: open)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    ArtworkView(track: track, root: root, size: compact ? 24 : 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        .contentTransition(.opacity)
                        if !compact, !artist.isEmpty {
                            Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                .contentTransition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: track?.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("展开播放器")
            .accessibilityIdentifier("mini-player-open")
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
        .simultaneousGesture(MiniPlayerReopenGesture(onReopen: open))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mini-player")
    }
}

private extension View {
    func searchReselect(title: String, onReselect: @escaping () -> Void) -> some View {
        tabReselect(title: title, onReselect: onReselect)
    }

    func tabReselect(title: String, onReselect: @escaping () -> Void) -> some View {
        background { SearchTabReselect(title: title, onReselect: onReselect) }
    }
}

enum PlaylistTabNavigation {
    /// All detail pages are path entries. The home stays put.
    enum Step {
        case stay
        case popPath
    }

    static func step(pathIsEmpty: Bool) -> Step {
        if !pathIsEmpty { return .popPath }
        return .stay
    }

    static func shouldReturnHome(pathIsEmpty: Bool) -> Bool {
        step(pathIsEmpty: pathIsEmpty) != .stay
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
