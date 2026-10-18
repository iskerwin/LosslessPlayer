import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    @State private var tab = 0
    @State private var showPlayer = false
    @State private var showSources = false
    @State private var importKind: ImportKind = .files
    @State private var pickerPresented = false
    @State private var query = ""
    @State private var playlistName = ""
    @State private var creatingPlaylist = false
    @State private var playlistTrack: Track?
    @State private var pendingDelete: Track?
    enum ImportKind { case files, folders }

    var body: some View {
        playerTabs
            .tint(.orange)
            .sheet(isPresented: $showPlayer) { NowPlayingView(library: library, player: player) }
            .sheet(isPresented: $showSources) { SourcesView(library: library, player: player) }
            .fileImporter(isPresented: $pickerPresented,
                allowedContentTypes: importKind == .folders ? [.folder] : [.audio], allowsMultipleSelection: true) { result in
                let kind = importKind
                switch result {
                case .success(let urls):
                    if kind == .folders { library.startAddFolders(urls) } else { library.startImport(urls) }
                case .failure(let error): library.errorMessage = error.localizedDescription
                }
            }
            .alert("新建歌单", isPresented: $creatingPlaylist) {
                TextField("歌单名称", text: $playlistName)
                Button("创建") {
                    if let list = library.createPlaylist(playlistName), let track = playlistTrack { library.add(track, to: list) }
                    playlistName = ""; playlistTrack = nil
                }
                Button("取消", role: .cancel) { playlistTrack = nil }
            }
            .confirmationDialog("从资料库移除歌曲？", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible) {
                if let track = pendingDelete {
                    Button("移除 \(track.title)", role: .destructive) {
                        player.stopIfCurrent(track); library.remove(track); pendingDelete = nil
                    }
                }
            } message: { Text("原文件不会删除。从扫描文件夹移除的歌曲，在后续扫描中保持隐藏。") }
            .alert("无法完成操作", isPresented: Binding(
                get: { library.errorMessage != nil || player.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil; player.errorMessage = nil } }
            )) { Button("好") { library.errorMessage = nil; player.errorMessage = nil } }
            message: { Text(library.errorMessage ?? player.errorMessage ?? "") }
    }

    @ViewBuilder private var playerTabs: some View {
        if #available(iOS 26.1, *) {
            tabs.tabBarMinimizeBehavior(.onScrollDown).tabViewBottomAccessory(isEnabled: player.current != nil) {
                MiniPlayer(library: library, player: player) { showPlayer = true }
            }
        } else if #available(iOS 26.0, *) {
            tabs.tabBarMinimizeBehavior(.onScrollDown).tabViewBottomAccessory {
                if player.current != nil { MiniPlayer(library: library, player: player) { showPlayer = true } }
            }
        } else {
            tabs.safeAreaInset(edge: .bottom) {
                if player.current != nil {
                    MiniPlayer(library: library, player: player) { showPlayer = true }
                        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24)).padding(.horizontal)
                }
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            NavigationStack {
                libraryHome.navigationTitle("资料库").toolbar { importMenu }
                    .navigationDestination(for: LibraryRoute.self) { route in destination(route) }
            }.tabItem { Label("资料库", systemImage: "square.stack.fill") }.tag(0)
            NavigationStack {
                collection(library.tracks.filter(\.favorite), title: "收藏")
                    .toolbar { importMenu }
            }.tabItem { Label("收藏", systemImage: "star.fill") }.tag(1)
            NavigationStack {
                collection(library.tracks.filter { query.isEmpty || "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query) }, title: "搜索")
                    .searchable(text: $query, prompt: "歌曲、艺术家、专辑")
            }.tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(2)
        }
    }

    private var importMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("添加音乐文件夹", systemImage: "folder.badge.plus") { importKind = .folders; pickerPresented = true }
                Button("导入音乐文件", systemImage: "square.and.arrow.down") { importKind = .files; pickerPresented = true }
                Button("新建歌单", systemImage: "music.note.list") { creatingPlaylist = true }
                Button("管理文件夹", systemImage: "folder") { showSources = true }
            } label: { Image(systemName: "plus.circle").font(.title3) }
                .disabled(library.importing)
                .accessibilityLabel("添加音乐与管理资料库")
        }
    }

    private var libraryHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 0) {
                    libraryLink("歌单", icon: "music.note.list", route: .playlists)
                    Divider().padding(.leading, 48)
                    libraryLink("艺术家", icon: "music.mic", route: .artists)
                    Divider().padding(.leading, 48)
                    libraryLink("专辑", icon: "square.stack", route: .albums)
                    Divider().padding(.leading, 48)
                    libraryLink("歌曲", icon: "music.note", route: .songs)
                }
                if library.importing { scanProgress }
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
                        ForEach(recentAlbums, id: \.id) { album in
                            NavigationLink(value: LibraryRoute.album(album.id)) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ArtworkView(track: album.tracks.first, root: library.root, size: nil).aspectRatio(1, contentMode: .fit)
                                    Text(album.name).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                                    Text(album.artist).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(.horizontal, 22).padding(.bottom, 24)
        }.background(Color(uiColor: .systemBackground))
    }

    private var recentAlbums: [AlbumGroup] { AlbumGroup.groups(library.tracks).sorted { $0.latest > $1.latest } }
    private var scanProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("正在整理音乐").font(.headline); Spacer(); Button("取消") { library.cancelScan() } }
            ProgressView(value: library.progress)
            Text(library.progressText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
    }

    private func libraryLink(_ title: String, icon: String, route: LibraryRoute) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 18) {
                Image(systemName: icon).foregroundStyle(.orange).font(.title2).frame(width: 26)
                Text(title).font(.title3).foregroundStyle(.primary)
                Spacer(); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }.padding(.vertical, 14)
        }
    }

    @ViewBuilder private func destination(_ route: LibraryRoute) -> some View {
        switch route {
        case .songs: collection(library.tracks, title: "歌曲")
        case .artists:
            List(Array(Set(library.tracks.map(\.artist))).sorted(), id: \.self) { artist in
                NavigationLink(value: LibraryRoute.artist(artist)) { Label(artist, systemImage: "person.crop.circle") }
            }.navigationTitle("艺术家")
        case .artist(let artist): collection(library.tracks.filter { $0.artist == artist }, title: artist)
        case .albums:
            List(AlbumGroup.groups(library.tracks)) { album in
                NavigationLink(value: LibraryRoute.album(album.id)) {
                    HStack { ArtworkView(track: album.tracks.first, root: library.root, size: 56)
                        VStack(alignment: .leading) { Text(album.name); Text(album.artist).font(.caption).foregroundStyle(.secondary) } }
                }
            }.navigationTitle("专辑")
        case .album(let id): collection(library.tracks.filter { $0.albumID == id }, title: library.tracks.first { $0.albumID == id }?.album ?? "专辑", album: true)
        case .playlists:
            List {
                Button("新建歌单", systemImage: "plus") { creatingPlaylist = true }
                ForEach(library.snapshot.playlists) { playlist in
                    NavigationLink(value: LibraryRoute.playlist(playlist.id)) {
                        Label { VStack(alignment: .leading) {
                            Text(playlist.name); Text("\(playlist.trackIDs.count) 首歌曲").font(.caption).foregroundStyle(.secondary)
                        } } icon: { Image(systemName: "music.note.list") }
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button("删除歌单", role: .destructive) { library.removePlaylist(playlist) }
                    }
                }
            }.navigationTitle("歌单")
        case .playlist(let id):
            let playlist = library.snapshot.playlists.first { $0.id == id }
            collection((playlist?.trackIDs ?? []).compactMap { id in library.tracks.first { $0.id == id } }, title: playlist?.name ?? "歌单", playlist: playlist)
        }
    }

    private func collection(_ tracks: [Track], title: String, album: Bool = false, playlist: Playlist? = nil) -> some View {
        let sorted = album ? tracks.sorted { a, b in
            if a.trackNumber != b.trackNumber { return (a.trackNumber ?? Int.max) < (b.trackNumber ?? Int.max) }
            return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
        } : (playlist == nil ? tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : tracks)
        return List {
            if album, let first = sorted.first {
                VStack(spacing: 12) {
                    ArtworkView(track: first, root: library.root, size: 210).padding(.top, 12)
                    Text(first.album).font(.title2.bold()); Text(first.artist).foregroundStyle(.orange)
                }.frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
            if !sorted.isEmpty {
                HStack {
                    Button { if let first = sorted.first(where: \.available) { player.load(first, context: sorted) } } label: {
                        Label("播放", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    Button {
                        let shuffled = sorted.filter(\.available).shuffled()
                        if let first = shuffled.first { player.load(first, context: shuffled) }
                    } label: { Label("随机播放", systemImage: "shuffle").frame(maxWidth: .infinity) }
                }.buttonStyle(.bordered).listRowSeparator(.hidden)
            }
            ForEach(sorted) { track in
                Button { player.load(track, context: sorted) } label: {
                    SongRow(track: track, root: library.root, current: player.current?.id == track.id)
                }.buttonStyle(.plain)
                .contextMenu { trackMenu(track) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("移除", role: .destructive) {
                        if let playlist { library.removeFromPlaylist(track, playlist: playlist) } else { pendingDelete = track }
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button { library.toggleFavorite(track) } label: { Label("收藏", systemImage: "star") }.tint(.orange)
                }
                .sensoryFeedback(.selection, trigger: track.favorite)
            }
            if sorted.isEmpty { ContentUnavailableView("还没有歌曲", systemImage: "music.note", description: Text("从资料库添加音乐，或更换搜索关键词。")) }
        }.listStyle(.plain).navigationTitle(title)
    }

    @ViewBuilder private func trackMenu(_ track: Track) -> some View {
        Button(track.favorite ? "取消收藏" : "收藏", systemImage: "star") { library.toggleFavorite(track) }
        Button("接下来播放", systemImage: "text.line.first.and.arrowtriangle.forward") { player.enqueue(track, next: true) }
        Button("最后播放", systemImage: "text.line.last.and.arrowtriangle.forward") { player.enqueue(track, next: false) }
        Menu("添加到歌单", systemImage: "text.badge.plus") {
            ForEach(library.snapshot.playlists) { list in Button(list.name) { library.add(track, to: list) } }
            Button("新建歌单") { playlistTrack = track; creatingPlaylist = true }
        }
        Button("从资料库移除", systemImage: "trash", role: .destructive) { pendingDelete = track }
    }
}

private enum LibraryRoute: Hashable { case songs, artists, albums, playlists, artist(String), album(String), playlist(UUID) }
struct AlbumGroup: Identifiable {
    var id: String
    var name: String
    var artist: String
    var tracks: [Track]
    var latest: Date { tracks.compactMap(\.addedAt).max() ?? .distantPast }
    static func groups(_ tracks: [Track]) -> [Self] {
        Dictionary(grouping: tracks, by: \.albumID).map { id, tracks in
            Self(id: id, name: tracks[0].album, artist: tracks[0].artist, tracks: tracks)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct SongRow: View {
    let track: Track
    let root: URL
    var current = false
    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: track, root: root, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).lineLimit(1).foregroundStyle(current ? Color.orange : Color.primary)
                Text(track.available ? track.artist : "文件已失效 · 请重新扫描").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if track.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange) }
            if current { Image(systemName: "waveform").foregroundStyle(.orange) }
            else { Text(clock(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }.padding(.vertical, 4).opacity(track.available ? 1 : 0.5)
    }
}

struct ArtworkView: View {
    let track: Track?
    let root: URL
    var size: CGFloat?
    var body: some View {
        Group {
            if let name = track?.artworkFilename, let image = UIImage(contentsOfFile: root.appendingPathComponent(name).path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.orange.opacity(0.85), .red.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").resizable().scaledToFit().padding(30).foregroundStyle(.white.opacity(0.9))
                }
            }
        }.frame(width: size, height: size).aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: (size ?? 150) < 80 ? 7 : 14))
            .accessibilityHidden(true)
    }
}

struct MiniPlayer: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    var open: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack { ArtworkView(track: player.current, root: library.root, size: 40)
                    Text(player.current?.title ?? "未在播放").font(.subheadline.weight(.medium)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading) }
            }.buttonStyle(.plain).accessibilityLabel("打开正在播放")
            Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 44) }
                .accessibilityLabel(player.playing ? "暂停" : "播放")
            Button { player.skip() } label: { Image(systemName: "forward.end.fill").frame(width: 40, height: 44) }.accessibilityLabel("下一首")
        }.padding(.horizontal, 12).padding(.vertical, 5).foregroundStyle(.primary)
    }
}

func clock(_ seconds: Double) -> String {
    let value = seconds.isFinite ? Int(max(0, seconds)) : 0
    return String(format: "%d:%02d", value / 60, value % 60)
}
