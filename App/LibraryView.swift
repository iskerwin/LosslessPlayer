import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    @State private var tab = AppTab.library
    @FocusState private var searchFieldFocused: Bool
    @State private var showPlayer = false
    @State private var showSources = false
    @State private var importKind: ImportKind = .files
    @State private var pickerPresented = false
    @State private var query = ""
    @State private var playlistName = ""
    @State private var creatingPlaylist = false
    @State private var playlistTrack: Track?
    @State private var playlistTarget: Track?
    @State private var songPicker: Playlist?
    @State private var pendingDelete: Track?
    @State private var renamingPlaylist: Playlist?
    @State private var exportPresented = false
    @State private var exportText = ""
    @State private var exportName = "playlist"
    @AppStorage("librarySort") private var sortRaw = LibrarySort.title.rawValue
    @AppStorage("albumSort") private var albumSortRaw = LibrarySort.album.rawValue
    enum ImportKind { case files, folders, playlist }

    var body: some View {
        playerTabs
            .tint(.orange)
            .sheet(isPresented: $showPlayer) { NowPlayingView(library: library, player: player) }
            .sheet(isPresented: $showSources) { SourcesView(library: library, player: player) }
            .fileImporter(isPresented: $pickerPresented, allowedContentTypes: pickerTypes, allowsMultipleSelection: true) { result in
                let kind = importKind
                switch result {
                case .success(let urls):
                    switch kind {
                    case .folders: library.startAddFolders(urls)
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
            .sheet(item: $playlistTarget) { track in
                AddToPlaylistSheet(library: library, tracks: [track])
            }
            .sheet(item: $songPicker) { playlist in
                SongPickerSheet(library: library, playlist: playlist)
            }
            .alert("新建歌单", isPresented: $creatingPlaylist) {
                TextField("歌单名称", text: $playlistName)
                Button("创建") {
                    if let list = library.createPlaylist(playlistName), let track = playlistTrack { library.add(track, to: list) }
                    playlistName = ""; playlistTrack = nil
                }
                Button("取消", role: .cancel) { playlistTrack = nil }
            }
            .confirmationDialog(RemovalNotice.title(for: pendingDelete), isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible) {
                if let track = pendingDelete {
                    Button(RemovalNotice.deletesAppCopy(track) ? "删除副本" : "从资料库移除", role: .destructive) {
                        player.stopIfCurrent(track); library.remove(track); pendingDelete = nil
                    }
                }
            } message: {
                Text(pendingDelete.map(RemovalNotice.message(for:)) ?? "")
            }
            .alert("无法完成操作", isPresented: Binding(
                get: { !showSources && (library.errorMessage != nil || player.errorMessage != nil) },
                set: { if !$0 { library.errorMessage = nil; player.errorMessage = nil } }
            )) { Button("好") { library.errorMessage = nil; player.errorMessage = nil } }
            message: { Text([library.errorMessage, player.errorMessage].compactMap { $0 }.joined(separator: "\n")) }
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
            }.tabItem { Label("资料库", systemImage: "square.stack.fill") }.tag(AppTab.library)
            NavigationStack {
                PlaylistHome(library: library, onRename: { playlist in
                    playlistName = playlist.name
                    renamingPlaylist = playlist
                }, onCreate: { creatingPlaylist = true })
                .toolbar { importMenu }
                .navigationDestination(for: LibraryRoute.self) { route in destination(route) }
            }.tabItem { Label("歌单", systemImage: "music.note.list") }.tag(AppTab.playlists)
            NavigationStack {
                collection(library.tracks.filter(\.favorite), title: "收藏")
                    .toolbar { importMenu }
            }.tabItem { Label("收藏", systemImage: "star.fill") }.tag(AppTab.favorites)
            NavigationStack {
                searchPage
            }.tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(AppTab.search)
        }
        .onChange(of: tab) { _, new in
            if new == .search { focusSearchSoon() } else { searchFieldFocused = false }
        }
    }

    private var searchPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("歌曲、艺术家、专辑", text: $query)
                    .focused($searchFieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button {
                        query = ""
                        searchFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture { searchFieldFocused = true }
            collection(library.tracks.filter { $0.matchesSearch(query) }, title: "搜索")
        }
        .background(Color(uiColor: .systemBackground))
        .scrollDismissesKeyboard(.interactively)
        .onAppear { focusSearchSoon() }
    }

    private func focusSearchSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard tab == .search else { return }
            searchFieldFocused = true
        }
    }

    private var importMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("添加音乐文件夹", systemImage: "folder.badge.plus") { importKind = .folders; pickerPresented = true }
                Button("导入音乐文件", systemImage: "square.and.arrow.down") { importKind = .files; pickerPresented = true }
                Button("新建歌单", systemImage: "music.note.list") { creatingPlaylist = true }
                Button("导入播放列表", systemImage: "list.bullet.rectangle") { importKind = .playlist; pickerPresented = true }
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
                    libraryLink("艺术家", icon: "music.mic", route: .artists)
                    Divider().padding(.leading, 48)
                    libraryLink("专辑", icon: "square.stack", route: .albums)
                    Divider().padding(.leading, 48)
                    libraryLink("歌曲", icon: "music.note", route: .songs)
                    Divider().padding(.leading, 48)
                    libraryLink("最近播放", icon: "clock", route: .recent)
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

    private var pickerTypes: [UTType] {
        switch importKind {
        case .folders: return [.folder]
        case .files: return [.audio]
        case .playlist: return PlaylistFileTypes.readable
        }
    }
    private var recentAlbums: [AlbumGroup] { AlbumGroup.groups(library.tracks).sorted { $0.latest > $1.latest } }
    private var recentlyPlayed: [Track] {
        library.tracks.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }
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
        case .songs: collection(library.tracks, title: "歌曲", reflectsPlayback: true)
        case .artists:
            List(Array(Set(library.tracks.map(\.artist))).sorted(), id: \.self) { artist in
                NavigationLink(value: LibraryRoute.artist(artist)) { Label(artist, systemImage: "person.crop.circle") }
            }.navigationTitle("艺术家")
        case .artist(let artist): collection(library.tracks.filter { $0.artist == artist }, title: artist)
        case .albums:
            List(AlbumGroup.groups(library.tracks)) { album in
                NavigationLink(value: LibraryRoute.album(album.id)) {
                    HStack { ArtworkView(track: album.tracks.first { $0.artworkFilename != nil } ?? album.tracks.first, root: library.root, size: 56)
                        VStack(alignment: .leading) { Text(album.name); Text(album.artist).font(.caption).foregroundStyle(.secondary) } }
                }
            }.navigationTitle("专辑")
        case .album(let id): collection(library.tracks.filter { $0.albumID == id }, title: library.tracks.first { $0.albumID == id }?.album ?? "专辑", album: true)
        case .recent: collection(recentlyPlayed, title: "最近播放", preserveOrder: true, reflectsPlayback: true)
        case .playlist(let id):
            let playlist = library.snapshot.playlists.first { $0.id == id }
            collection((playlist?.trackIDs ?? []).compactMap { id in library.tracks.first { $0.id == id } }, title: playlist?.name ?? "歌单", playlist: playlist)
        }
    }

    private func collection(_ tracks: [Track], title: String, album: Bool = false, playlist: Playlist? = nil, preserveOrder: Bool = false, reflectsPlayback: Bool = false) -> some View {
        let activeSort: LibrarySort? = {
            if playlist != nil || preserveOrder { return nil }
            if album { return LibrarySort(rawValue: albumSortRaw) ?? .album }
            return LibrarySort(rawValue: sortRaw) ?? .title
        }()
        let sorted = activeSort?.sorted(tracks) ?? tracks
        return List {
            if album, let first = sorted.first {
                VStack(spacing: 12) {
                    ArtworkView(track: sorted.first { $0.artworkFilename != nil } ?? first, root: library.root, size: 210).padding(.top, 12)
                    Text(first.album).font(.title2.bold()); Text(first.albumArtistName).foregroundStyle(.orange)
                }.frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
            if let playlist {
                PlaylistCover(playlist: playlist, library: library)
                    .frame(width: 180)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                Button {
                    songPicker = library.snapshot.playlists.first { $0.id == playlist.id } ?? playlist
                } label: {
                    Label("添加歌曲", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .listRowSeparator(.hidden)
            }
            if !sorted.isEmpty {
                playbackCapsules(sorted, reflectsPlayback: reflectsPlayback)
            }
            ForEach(sorted) { track in
                Button { player.load(track, context: sorted) } label: {
                    SongRow(track: track, root: library.root, current: player.current?.id == track.id, indexLabel: album ? indexLabel(track) : nil)
                }.buttonStyle(.plain)
                .contextMenu { trackMenu(track, playlist: playlist) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("移除", role: .destructive) {
                        if let playlist { library.removeFromPlaylist(track, playlist: playlist) } else { pendingDelete = track }
                    }
                    Button("加入歌单") { playlistTarget = track }.tint(.orange)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button { library.toggleFavorite(track) } label: { Label(track.favorite ? "取消收藏" : "收藏", systemImage: "star") }.tint(.orange)
                }
                .sensoryFeedback(.selection, trigger: track.favorite)
            }
            .onMove { offsets, destination in
                guard let playlist else { return }
                library.moveTracks(in: playlist, displayed: sorted.map(\.id), from: offsets, to: destination)
            }
            if sorted.isEmpty { ContentUnavailableView("还没有歌曲", systemImage: "music.note", description: Text("从资料库添加音乐，或更换搜索关键词。")) }
        }
        .listStyle(.plain).navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let playlist {
                    EditButton()
                    Menu {
                        Button("重命名", systemImage: "pencil") { playlistName = playlist.name; renamingPlaylist = playlist }
                        Button("导出 m3u", systemImage: "square.and.arrow.up") { beginExport(playlist, tracks: sorted) }
                    } label: { Image(systemName: "ellipsis.circle") }
                } else if activeSort != nil {
                    Menu {
                        ForEach(LibrarySort.allCases.filter { album || $0 != .album }) { item in
                            Button {
                                if album { albumSortRaw = item.rawValue } else { sortRaw = item.rawValue }
                            } label: {
                                if item == activeSort { Label(item.label, systemImage: "checkmark") } else { Text(item.label) }
                            }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .accessibilityLabel("排序")
                }
            }
        }
    }

    private func playbackCapsules(_ tracks: [Track], reflectsPlayback: Bool) -> some View {
        let active = reflectsPlayback && PlaybackContext.matches(list: tracks.map(\.id), context: player.contextIDs)
        let playingHere = active && player.playing
        let shuffleHere = active && player.shuffle
        return HStack {
            capsule(playingHere ? "暂停" : "播放", icon: playingHere ? "pause.fill" : "play.fill", highlighted: playingHere, tinted: active && !playingHere) {
                if playingHere { player.pause() }
                else if active, player.current != nil { player.resume() }
                else { player.play(tracks, shuffled: false) }
            }
            capsule("随机播放", icon: "shuffle", highlighted: shuffleHere, tinted: false) {
                if active { player.toggleShuffle() }
                else { player.play(tracks, shuffled: true) }
            }
        }
        .listRowSeparator(.hidden)
    }

    @ViewBuilder private func capsule(_ title: String, icon: String, highlighted: Bool, tinted: Bool, action: @escaping () -> Void) -> some View {
        let label = Label(title, systemImage: icon).frame(maxWidth: .infinity)
        if highlighted {
            Button(action: action) { label }.buttonStyle(.borderedProminent).tint(.orange)
        } else {
            Button(action: action) { label }.buttonStyle(.bordered).tint(tinted ? .orange : .primary)
        }
    }

    private func indexLabel(_ track: Track) -> String? {
        guard let number = track.trackNumber else { return nil }
        if let disc = track.discNumber, disc > 0 { return "\(disc)-\(number)" }
        return "\(number)"
    }

    private func beginExport(_ playlist: Playlist, tracks: [Track]) {
        exportText = PlaylistExchange.render(tracks)
        exportName = playlist.name.replacingOccurrences(of: "/", with: "-")
        exportPresented = true
    }

    @ViewBuilder private func trackMenu(_ track: Track, playlist: Playlist? = nil) -> some View {
        Button(track.favorite ? "取消收藏" : "收藏", systemImage: "star") { library.toggleFavorite(track) }
        Button("接下来播放", systemImage: "text.line.first.and.arrowtriangle.forward") { player.enqueue(track, next: true) }
        Button("最后播放", systemImage: "text.line.last.and.arrowtriangle.forward") { player.enqueue(track, next: false) }
        Button("添加到歌单", systemImage: "text.badge.plus") { playlistTarget = track }
        if let playlist {
            Button("设为歌单封面", systemImage: "photo") { library.setCover(track, for: playlist) }
        }
        Button("从资料库移除", systemImage: "trash", role: .destructive) { pendingDelete = track }
    }
}

enum LibraryRoute: Hashable {
    case songs, artists, albums, recent
    case artist(String), album(String), playlist(UUID)
}

private enum AppTab: Hashable {
    case library, playlists, favorites, search
}
struct AlbumGroup: Identifiable {
    var id: String
    var name: String
    var artist: String
    var tracks: [Track]
    var latest: Date { tracks.compactMap(\.addedAt).max() ?? .distantPast }
    static func groups(_ tracks: [Track]) -> [Self] {
        Dictionary(grouping: tracks, by: \.albumID).map { id, tracks in
            Self(id: id, name: tracks[0].album, artist: tracks[0].albumArtistName, tracks: tracks)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct SongRow: View {
    let track: Track
    let root: URL
    var current = false
    var indexLabel: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            if let indexLabel {
                Text(indexLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            }
            ArtworkView(track: track, root: root, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).lineLimit(1).foregroundStyle(current ? Color.orange : Color.primary)
                Text(track.available ? artistDetail : "文件已失效 · 请重新扫描").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if track.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange) }
            if current { Image(systemName: "waveform").foregroundStyle(.orange) }
            else { Text(clock(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }.padding(.vertical, 4).opacity(track.available ? 1 : 0.5)
    }
    private var artistDetail: String {
        guard track.playCount > 0 else { return track.artist }
        return "\(track.artist) · \(track.playCount) 次"
    }
}

final class ArtworkCache {
    static let shared = ArtworkCache()
    private let images = NSCache<NSString, UIImage>()
    func image(at url: URL) -> UIImage? {
        let key = url.path as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
    func removeAll() { images.removeAllObjects() }
}

struct ArtworkView: View {
    let track: Track?
    let root: URL
    var size: CGFloat?
    var body: some View {
        Group {
            if let name = track?.artworkFilename, let image = ArtworkCache.shared.image(at: root.appendingPathComponent(name)) {
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
            ArtworkView(track: player.current, root: library.root, size: 40)
            Text(player.current?.title ?? "未在播放")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("打开正在播放")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, open)
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(player.playing ? "暂停" : "播放")
            Button { player.skip() } label: {
                Image(systemName: "forward.end.fill").frame(width: 40, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("下一首")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
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
