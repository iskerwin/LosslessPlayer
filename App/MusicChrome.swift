import SwiftUI

/// Explicit color also keeps native glass tabs consistent when presented in dark mode.
enum MusicTheme {
    static let accent = Color(red: 1, green: 45.0 / 255, blue: 85.0 / 255)
}

/// List pages only offer these two actions. Neither one reads pause, shuffle, or repeat.
enum CollectionTransport: String, CaseIterable, Hashable {
    case playFromStart
    case shufflePlay

    var title: String {
        switch self {
        case .playFromStart: return "播放"
        case .shufflePlay: return "随机播放"
        }
    }

    var symbol: String {
        switch self {
        case .playFromStart: return "play.fill"
        case .shufflePlay: return "shuffle"
        }
    }

    /// Collection capsules never change appearance while audio is playing.
    var reflectsPlaybackState: Bool { false }
}

struct SongMenuModel: Equatable {
    var favorite: Bool
    var hasLyrics: Bool
    var inPlaylist = false

    var favoriteTitle: String { favorite ? "取消收藏" : "收藏" }
    var includesLyrics: Bool { hasLyrics }
    var includesPlaylistExtras: Bool { inPlaylist }

    static let baseTitles = [
        "收藏", "添加到歌单", "下一首播放", "稍后播放",
        "前往专辑", "前往艺术家", "查看完整歌词", "从资料库中删除"
    ]
}

struct MenuAction: Identifiable {
    var id: String
    var title: String
    var symbol: String
    var role: ButtonRole? = nil
    var action: () -> Void
}

struct MenuGroup: Identifiable {
    var id: String
    var entries: [MenuAction]
}

extension SongHandlers {
    static var ignore: SongHandlers {
        SongHandlers(
            play: { _ in }, favorite: { _ in }, playlist: { _ in }, playNext: { _ in }, addToQueue: { _ in },
            album: { _ in }, artist: { _ in }, lyrics: { _ in }, delete: { _ in }
        )
    }
}

enum SongMenuCatalog {
    static func groups(for track: Track, handlers: SongHandlers) -> [MenuGroup] {
        let model = SongMenuModel(
            favorite: track.favorite,
            hasLyrics: track.hasLyrics,
            inPlaylist: handlers.removeFromPlaylist != nil || handlers.setCover != nil
        )
        var navigation = [
            MenuAction(id: "album", title: "前往专辑", symbol: "music.note") { handlers.album(track) },
            MenuAction(id: "artist", title: "前往艺术家", symbol: "music.mic") { handlers.artist(track) }
        ]
        if model.includesLyrics {
            navigation.append(MenuAction(id: "lyrics", title: "查看完整歌词", symbol: "quote.bubble") { handlers.lyrics(track) })
        }
        var groups = [
            MenuGroup(id: "favorite", entries: [
                MenuAction(id: "favorite", title: model.favoriteTitle, symbol: track.favorite ? "star.fill" : "star") { handlers.favorite(track) }
            ]),
            MenuGroup(id: "playlist", entries: [
                MenuAction(id: "add-playlist", title: "添加到歌单", symbol: "text.badge.plus") { handlers.playlist(track) }
            ]),
            MenuGroup(id: "queue", entries: [
                MenuAction(id: "next", title: "下一首播放", symbol: "text.insert") { handlers.playNext(track) },
                MenuAction(id: "later", title: "稍后播放", symbol: "text.append") { handlers.addToQueue(track) }
            ]),
            MenuGroup(id: "go", entries: navigation)
        ]
        if model.includesPlaylistExtras {
            var extras: [MenuAction] = []
            if let setCover = handlers.setCover {
                extras.append(MenuAction(id: "cover", title: "设为歌单封面", symbol: "photo") { setCover(track) })
            }
            if let remove = handlers.removeFromPlaylist {
                extras.append(MenuAction(id: "remove", title: "从歌单中移除", symbol: "minus.circle") { remove(track) })
            }
            groups.append(MenuGroup(id: "membership", entries: extras))
        }
        groups.append(MenuGroup(id: "delete", entries: [
            MenuAction(id: "delete", title: "从资料库中删除", symbol: "trash", role: .destructive) { handlers.delete(track) }
        ]))
        return groups
    }
}

struct SectionsMenu<Trigger: View>: View {
    var sections: [MenuGroup]
    @ViewBuilder var label: () -> Trigger

    var body: some View {
        Menu {
            ForEach(sections) { group in
                Section {
                    ForEach(group.entries) { entry in
                        Button(role: entry.role, action: entry.action) {
                            Label(entry.title, systemImage: entry.symbol)
                        }
                    }
                }
            }
        } label: {
            label()
        }
    }
}

struct ActionsContext<Preview: View>: ViewModifier {
    var sections: [MenuGroup]
    var preview: Preview

    func body(content: Content) -> some View {
        content.contextMenu {
            ForEach(sections) { group in
                Section {
                    ForEach(group.entries) { entry in
                        Button(role: entry.role, action: entry.action) {
                            Label(entry.title, systemImage: entry.symbol)
                        }
                    }
                }
            }
        } preview: {
            preview
        }
    }
}

struct TrackBatch: Identifiable {
    let id = UUID()
    var tracks: [Track]
}

struct ImportCommands {
    var addFolder: () -> Void
    var addFiles: () -> Void
    var newPlaylist: () -> Void
    var importPlaylist: () -> Void
    var showFolders: () -> Void
    var folderPlaylists: (() -> Void)? = nil
}

struct SongHandlers {
    var play: (Track) -> Void
    var favorite: (Track) -> Void
    var playlist: (Track) -> Void
    var playNext: (Track) -> Void
    var addToQueue: (Track) -> Void
    var album: (Track) -> Void
    var artist: (Track) -> Void
    var lyrics: (Track) -> Void
    var delete: (Track) -> Void
    var removeFromPlaylist: ((Track) -> Void)? = nil
    var setCover: ((Track) -> Void)? = nil
}

struct ToolbarChrome: ViewModifier {
    func body(content: Content) -> some View {
        content.tint(.primary)
    }
}

extension View {
    func trailingGlass<M: View>(@ViewBuilder more: () -> M) -> some View {
        modifier(TrailingGlassModifier<EmptyView, M>(sort: nil, more: more()))
    }

    func trailingGlass<S: View, M: View>(@ViewBuilder sort: () -> S, @ViewBuilder more: () -> M) -> some View {
        modifier(TrailingGlassModifier<S, M>(sort: sort(), more: more()))
    }
}

private struct TrailingGlassModifier<Sort: View, More: View>: ViewModifier {
    var sort: Sort?
    var more: More

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let sort { sort }
                more
            }
        }
    }
}

extension View {
    @ViewBuilder func softTopScrollEdge() -> some View {
        if #available(iOS 26, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

struct PlayShuffleBar: View {
    var enabled = true
    var play: () -> Void
    var shuffle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(CollectionTransport.allCases, id: \.self) { item in
                Button {
                    if item == .playFromStart { play() } else { shuffle() }
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.body.weight(.medium))
                        .foregroundStyle(MusicTheme.accent)
                        .frame(maxWidth: .infinity)
                }
                .modifier(CollectionGlassButton())
                .accessibilityLabel(item.title)
            }
        }
        .disabled(!enabled)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
        .listRowBackground(Color.clear)
    }
}

/// The play control fills every point that is not the trailing menu.
/// A tap at 70% of a normal row is still play, including padding and the gap before the ellipsis.
enum RowMetrics {
    static let menuWidth: CGFloat = 44
    static let leadingInset: CGFloat = 16
}

enum RowHitZone: Equatable {
    case play, menu
}

enum RowHitMap {
    static func zone(x: CGFloat, width: CGFloat, menuWidth: CGFloat) -> RowHitZone {
        guard width > 0 else { return .play }
        if menuWidth > 0, x >= width - menuWidth { return .menu }
        return .play
    }
}

struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear)
    }
}

struct EllipsisLabel: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(width: RowMetrics.menuWidth, height: 44)
            .contentShape(Rectangle())
    }
}

private struct CollectionGlassButton: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large).tint(.primary)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).tint(.primary)
        }
    }
}

struct SongRow: View {
    let track: Track
    let root: URL
    var current = false
    var playing = false
    var indexLabel: String? = nil
    var emphasis: Color = MusicTheme.accent

    var body: some View {
        HStack(spacing: 12) {
            if let indexLabel {
                Text(indexLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            ArtworkView(track: track, root: root, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(current ? emphasis : Color.primary)
                Text(track.available ? track.artist : "文件已失效 · 请重新扫描")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if current && playing {
                Image(systemName: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(emphasis)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(track.available ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(current ? "\(track.title)，\(track.artist)，正在播放" : "\(track.title)，\(track.artist)")
    }

    static func separatorInset(showsIndex: Bool) -> CGFloat {
        (showsIndex ? 36 + 12 : 0) + 48 + 12
    }
}

struct SongMenuPreview: View {
    let track: Track
    let root: URL

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: track, root: root, size: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 2) {
                    Text(track.album).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 260, maxWidth: 320, alignment: .leading)
    }
}

struct SongContextRow: View {
    let track: Track
    let root: URL
    var current = false
    var playing = false
    var indexLabel: String? = nil
    var showsMenu = true
    var emphasis: Color = MusicTheme.accent
    var showsLocalStatus = false
    var handlers: SongHandlers

    var body: some View {
        HStack(spacing: 0) {
            Button { handlers.play(track) } label: {
                SongRow(track: track, root: root, current: current, playing: playing, indexLabel: indexLabel, emphasis: emphasis)
                    .padding(.leading, RowMetrics.leadingInset)
            }
            .buttonStyle(RowPressStyle())
            if showsLocalStatus && track.available {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)
                    .accessibilityLabel("已在本地")
            }
            if showsMenu {
                SectionsMenu(sections: sections) { EllipsisLabel() }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityLabel("更多操作")
            }
        }
        .modifier(ActionsContext(sections: sections, preview: SongMenuPreview(track: track, root: root)))
        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
            dimensions[.leading] + RowMetrics.leadingInset + SongRow.separatorInset(showsIndex: indexLabel != nil)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .sensoryFeedback(.selection, trigger: track.favorite)
    }

    private var sections: [MenuGroup] { SongMenuCatalog.groups(for: track, handlers: handlers) }
}

struct MediaPreview: View {
    var title: String
    var subtitle: String
    var artwork: Track?
    var root: URL

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: artwork, root: root, size: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                HStack(spacing: 2) {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 260, maxWidth: 320, alignment: .leading)
    }
}

func importMenuGroup(_ commands: ImportCommands) -> MenuGroup {
    var entries = [
        MenuAction(id: "folder", title: "添加音乐文件夹", symbol: "folder.badge.plus", action: commands.addFolder),
        MenuAction(id: "files", title: "导入音乐文件", symbol: "square.and.arrow.down", action: commands.addFiles),
        MenuAction(id: "new", title: "新建歌单", symbol: "music.note.list", action: commands.newPlaylist),
        MenuAction(id: "playlist", title: "导入播放列表", symbol: "list.bullet.rectangle", action: commands.importPlaylist),
        MenuAction(id: "manage", title: "管理文件夹", symbol: "folder", action: commands.showFolders)
    ]
    if let action = commands.folderPlaylists {
        entries.insert(MenuAction(id: "folder-playlists", title: "从文件夹创建歌单", symbol: "folder.badge.plus", action: action), at: 1)
    }
    return MenuGroup(id: "import", entries: entries)
}
