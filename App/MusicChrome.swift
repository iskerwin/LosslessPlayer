import SwiftUI
import UIKit

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

struct SectionsMenu<Label: View>: View {
    var sections: [MenuGroup]
    @ViewBuilder var label: () -> Label

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
        if #available(iOS 26, *) {
            content
        } else {
            content.buttonStyle(.plain).padding(.horizontal, 10).frame(minHeight: 36)
        }
    }
}

extension View {
    func trailingGlass<M: View>(@ViewBuilder more: () -> M) -> some View {
        modifier(TrailingGlassModifier<EmptyView, M>(sort: nil, more: more()))
    }

    func trailingGlass<S: View, M: View>(@ViewBuilder sort: () -> S, @ViewBuilder more: () -> M) -> some View {
        modifier(TrailingGlassModifier<S, M>(sort: sort(), more: more()))
    }

    func circularBackButton(_ enabled: Bool = true) -> some View {
        modifier(CircularBackModifier(enabled: enabled))
    }
}

private struct TrailingGlassModifier<Sort: View, More: View>: ViewModifier {
    var sort: Sort?
    var more: More

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let sort { sort }
                    more
                }
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 0) {
                        if let sort {
                            sort
                            Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 1, height: 16)
                        }
                        more
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .background(.regularMaterial, in: Capsule())
                }
            }
        }
    }
}

private struct CircularBackModifier: ViewModifier {
    var enabled: Bool
    @Environment(\.dismiss) private var dismiss

    @ViewBuilder func body(content: Content) -> some View {
        if !enabled {
            content
        } else if #available(iOS 26, *) {
            content
        } else {
            content
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.backward")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .background(.regularMaterial, in: Circle())
                        .accessibilityLabel("返回")
                    }
                }
                .background { PopGestureEnabler().frame(width: 0, height: 0).allowsHitTesting(false) }
        }
    }
}

/// Keeps the swipe-back gesture after the system back button is replaced on iOS 17.
private struct PopGestureEnabler: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isUserInteractionEnabled = false
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        DispatchQueue.main.async {
            guard let gesture = controller.navigationController?.interactivePopGestureRecognizer else { return }
            gesture.isEnabled = true
            gesture.delegate = context.coordinator
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let count = (gestureRecognizer.view?.next as? UINavigationController)?.viewControllers.count ?? 2
            return count > 1
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
                CapsuleButton(
                    title: item.title,
                    systemImage: item.symbol,
                    chrome: .collection,
                    expands: true,
                    accessibilityLabel: item.title
                ) {
                    if item == .playFromStart { play() } else { shuffle() }
                }
            }
        }
        .disabled(!enabled)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
        .listRowBackground(Color.clear)
    }
}

struct EllipsisLabel: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 44)
            .contentShape(Rectangle())
    }
}

struct SongRow: View {
    let track: Track
    let root: URL
    var current = false
    var playing = false
    var indexLabel: String? = nil

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
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(current ? Color.orange : Color.primary)
                Text(track.available ? track.artist : "文件已失效 · 请重新扫描")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if current && playing {
                Image(systemName: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
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
    var handlers: SongHandlers

    var body: some View {
        HStack(spacing: 0) {
            Button { handlers.play(track) } label: {
                SongRow(track: track, root: root, current: current, playing: playing, indexLabel: indexLabel)
            }
            .buttonStyle(.plain)
            if showsMenu {
                SectionsMenu(sections: sections) { EllipsisLabel() }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("更多操作")
            }
        }
        .modifier(ActionsContext(sections: sections, preview: SongMenuPreview(track: track, root: root)))
        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
            dimensions[.leading] + SongRow.separatorInset(showsIndex: indexLabel != nil)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 4))
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
    MenuGroup(id: "import", entries: [
        MenuAction(id: "folder", title: "添加音乐文件夹", symbol: "folder.badge.plus", action: commands.addFolder),
        MenuAction(id: "files", title: "导入音乐文件", symbol: "square.and.arrow.down", action: commands.addFiles),
        MenuAction(id: "new", title: "新建歌单", symbol: "music.note.list", action: commands.newPlaylist),
        MenuAction(id: "playlist", title: "导入播放列表", symbol: "list.bullet.rectangle", action: commands.importPlaylist),
        MenuAction(id: "manage", title: "管理文件夹", symbol: "folder", action: commands.showFolders)
    ])
}
