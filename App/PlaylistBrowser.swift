import SwiftUI

struct PlaylistHome: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    var imports: ImportCommands
    var onOpen: (LibraryRoute) -> Void
    var onRename: (Playlist) -> Void
    var onCreate: () -> Void
    var onAddSongs: (Playlist) -> Void
    var onAddToPlaylist: ([Track]) -> Void
    @AppStorage("playlistLayout") private var layoutRaw = PlaylistLayout.grid.rawValue
    private var layout: PlaylistLayout { PlaylistLayout(rawValue: layoutRaw) ?? .grid }

    var body: some View {
        Group {
            if library.snapshot.playlists.isEmpty {
                ContentUnavailableView {
                    Label("还没有歌单", systemImage: "music.note.list")
                } description: {
                    Text("新建一个歌单，再把歌曲加进去。")
                } actions: {
                    Button("新建歌单", action: onCreate).buttonStyle(.borderedProminent)
                }
            } else if layout == .grid {
                grid
            } else {
                list
            }
        }
        .softTopScrollEdge()
        .navigationTitle("歌单")
        .navigationBarTitleDisplayMode(.large)
        .trailingGlass {
            Button {
                layoutRaw = layout.toggled.rawValue
            } label: {
                Image(systemName: layout == .grid ? "list.bullet" : "square.grid.2x2")
            }
            .accessibilityLabel(layout == .grid ? "切换为列表" : "切换为网格")
            .modifier(ToolbarChrome())
        } more: {
            SectionsMenu(sections: [
                MenuGroup(id: "create", entries: [
                    MenuAction(id: "new", title: "新建歌单", symbol: "music.note.list", action: onCreate)
                ]),
                importMenuGroup(imports)
            ]) {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("更多")
            .modifier(ToolbarChrome())
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 16)], spacing: 22) {
                ForEach(library.snapshot.playlists) { playlist in
                    Button { onOpen(.playlist(playlist.id)) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            PlaylistCover(playlist: playlist, library: library)
                            Text(playlist.name).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(.primary)
                            Text("\(playlist.trackIDs.count) 首歌曲").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowPressStyle())
                    .modifier(ActionsContext(
                        sections: playlistGroups(playlist),
                        preview: MediaPreview(title: playlist.name, subtitle: "\(playlist.trackIDs.count) 首歌曲", artwork: coverTrack(playlist), root: library.root)
                    ))
                }
            }
            .padding(22)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var list: some View {
        List {
            ForEach(library.snapshot.playlists) { playlist in
                HStack(spacing: 0) {
                    Button { onOpen(.playlist(playlist.id)) } label: {
                        HStack(spacing: 12) {
                            PlaylistCover(playlist: playlist, library: library).frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.name).lineLimit(1).foregroundStyle(.primary)
                                Text("\(playlist.trackIDs.count) 首歌曲").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                        }
                        .padding(.vertical, 8)
                        .padding(.leading, RowMetrics.leadingInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowPressStyle())
                    SectionsMenu(sections: playlistGroups(playlist)) { EllipsisLabel() }
                        .buttonStyle(.borderless)
                        .tint(.primary)
                        .accessibilityLabel("更多操作")
                }
                .swipeActions(allowsFullSwipe: false) {
                    Button("重命名") { onRename(playlist) }.tint(.orange)
                    Button("删除歌单", role: .destructive) { library.removePlaylist(playlist) }
                }
                .modifier(ActionsContext(
                    sections: playlistGroups(playlist),
                    preview: MediaPreview(title: playlist.name, subtitle: "\(playlist.trackIDs.count) 首歌曲", artwork: coverTrack(playlist), root: library.root)
                ))
                .alignmentGuide(.listRowSeparatorLeading) { dimensions in dimensions[.leading] + RowMetrics.leadingInset + 56 + 12 }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
    }

    private func playlistGroups(_ playlist: Playlist) -> [MenuGroup] {
        let tracks = tracks(in: playlist)
        return [
            MenuGroup(id: "play", entries: [
                MenuAction(id: "play", title: "播放", symbol: "play.fill") { player.play(tracks, shuffled: false) },
                MenuAction(id: "shuffle", title: "随机播放", symbol: "shuffle") { player.play(tracks, shuffled: true) }
            ]),
            MenuGroup(id: "queue", entries: [
                MenuAction(id: "next", title: "下一首播放", symbol: "text.insert") { player.enqueue(tracks, next: true) },
                MenuAction(id: "later", title: "稍后播放", symbol: "text.append") { player.enqueue(tracks, next: false) }
            ]),
            MenuGroup(id: "edit", entries: [
                MenuAction(id: "add-playlist", title: "添加到歌单", symbol: "text.badge.plus") { onAddToPlaylist(tracks) },
                MenuAction(id: "add-songs", title: "添加歌曲", symbol: "plus") { onAddSongs(playlist) },
                MenuAction(id: "rename", title: "重命名", symbol: "pencil") { onRename(playlist) }
            ]),
            MenuGroup(id: "delete", entries: [
                MenuAction(id: "delete", title: "删除歌单", symbol: "trash", role: .destructive) { library.removePlaylist(playlist) }
            ])
        ]
    }

    private func tracks(in playlist: Playlist) -> [Track] {
        playlist.trackIDs.compactMap { id in library.tracks.first { $0.id == id } }
    }

    private func coverTrack(_ playlist: Playlist) -> Track? {
        library.coverTrack(for: playlist)
    }
}

private enum PlaylistLayout: String {
    case grid, list
    var toggled: Self { self == .grid ? .list : .grid }
}

struct PlaylistCover: View {
    let playlist: Playlist
    @ObservedObject var library: LibraryStore

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { artwork.clipped() }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var artwork: some View {
        let choice = Self.choice(for: playlist, in: library)
        GeometryReader { geo in
            if choice.single {
                ArtworkView(track: choice.tracks.compactMap { $0 }.first, root: library.root, size: geo.size.width)
            } else {
                let cell = max(0, (geo.size.width - 2) / 2)
                VStack(spacing: 2) {
                    HStack(spacing: 2) { tile(choice.tracks, 0, cell); tile(choice.tracks, 1, cell) }
                    HStack(spacing: 2) { tile(choice.tracks, 2, cell); tile(choice.tracks, 3, cell) }
                }
            }
        }
    }

    private func tile(_ tracks: [Track?], _ index: Int, _ side: CGFloat) -> some View {
        ArtworkView(track: tracks.indices.contains(index) ? tracks[index] : nil, root: library.root, size: side)
    }

    static func choice(for playlist: Playlist, in library: LibraryStore) -> (tracks: [Track?], single: Bool) {
        let members = playlist.trackIDs.compactMap { id in library.tracks.first { $0.id == id } }
        if let coverID = playlist.coverTrackID,
           !members.contains(where: { $0.id == coverID }),
           let cover = library.tracks.first(where: { $0.id == coverID }) {
            return ([cover], true)
        }
        return choice(coverTrackID: playlist.coverTrackID, members: members)
    }

    static func choice(coverTrackID: UUID?, members: [Track]) -> (tracks: [Track?], single: Bool) {
        if let coverID = coverTrackID, let cover = members.first(where: { $0.id == coverID }) {
            return ([cover], true)
        }
        if members.count < 2 { return ([members.first], true) }
        var cells: [Track?] = Array(members.prefix(4))
        while cells.count < 4 { cells.append(nil) }
        return (cells, false)
    }
}

struct AddToPlaylistSheet: View {
    @ObservedObject var library: LibraryStore
    let tracks: [Track]
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("新建歌单") {
                    TextField("歌单名称", text: $newName)
                    Button("创建并加入") { createAndAdd() }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tracks.isEmpty)
                }
                Section("现有歌单") {
                    if library.snapshot.playlists.isEmpty {
                        Text("还没有歌单").foregroundStyle(.secondary)
                    }
                    ForEach(library.snapshot.playlists) { playlist in
                        Button {
                            library.add(tracks, to: playlist)
                            dismiss()
                        } label: {
                            HStack {
                                PlaylistCover(playlist: playlist, library: library).frame(width: 44, height: 44)
                                VStack(alignment: .leading) {
                                    Text(playlist.name).foregroundStyle(.primary)
                                    Text("\(playlist.trackIDs.count) 首").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("添加到歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .tint(.orange)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func createAndAdd() {
        guard let playlist = library.createPlaylist(newName) else { return }
        library.add(tracks, to: playlist)
        dismiss()
    }
}

struct SongPickerSheet: View {
    @ObservedObject var library: LibraryStore
    let playlist: Playlist
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: Set<UUID> = []
    @State private var searchFocused = false

    private var candidates: [Track] {
        let existing = Set(playlist.trackIDs)
        return library.tracks
            .filter { !existing.contains($0.id) && $0.matchesSearch(query) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("已选 \(selected.count) 首").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("全选") { selected = VisibleSongSelection.selectVisible(visibleIDs, in: selected) }
                        .disabled(visibleIDs.isEmpty || VisibleSongSelection.allVisibleSelected(visibleIDs, in: selected))
                    Button("取消全选") { selected = VisibleSongSelection.deselectVisible(visibleIDs, in: selected) }
                        .disabled(!VisibleSongSelection.anyVisibleSelected(visibleIDs, in: selected))
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
                List(candidates) { track in
                    Button { toggle(track) } label: {
                        HStack(spacing: 12) {
                            SongRow(track: track, root: library.root)
                            Image(systemName: selected.contains(track.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(track.id) ? Color.orange : Color.secondary)
                                .font(.title3)
                                .frame(width: RowMetrics.menuWidth)
                        }
                        .padding(.trailing, 4)
                        .padding(.leading, RowMetrics.leadingInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowPressStyle())
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .searchable(text: $query, isPresented: $searchFocused, prompt: "搜索要添加的歌曲")
            }
            .navigationTitle("添加歌曲")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加 (\(selected.count))") { commit() }
                        .disabled(selected.isEmpty)
                }
            }
            .onAppear { searchFocused = true }
        }
        .tint(.orange)
    }

    private var visibleIDs: [UUID] { candidates.map(\.id) }

    private func toggle(_ track: Track) {
        if selected.contains(track.id) { selected.remove(track.id) } else { selected.insert(track.id) }
    }

    private func commit() {
        guard let live = library.snapshot.playlists.first(where: { $0.id == playlist.id }) else { dismiss(); return }
        let chosen = library.tracks.filter { selected.contains($0.id) }
        library.add(chosen, to: live)
        dismiss()
    }

}
