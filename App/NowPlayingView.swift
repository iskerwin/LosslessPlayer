import SwiftUI
import AVKit
import MediaPlayer

struct NowPlayingView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    @ObservedObject private var playbackClock: PlaybackClock
    @Environment(\.dismiss) private var dismiss

    init(library: LibraryStore, player: PlayerStore) {
        self.library = library
        self.player = player
        _playbackClock = ObservedObject(wrappedValue: player.clock)
    }
    @State private var mode = 0
    @State private var scrubbing = false
    @State private var draft: Double = 0
    @State private var details = false
    private var current: Track? { library.tracks.first { $0.id == player.current?.id } }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color.orange.opacity(0.24), Color(uiColor: .systemBackground), Color.red.opacity(0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 25) {
                        if mode == 0 {
                            ArtworkView(track: current, root: library.root, size: nil)
                                .frame(maxWidth: 340).padding(.horizontal, 8)
                                .scaleEffect(player.playing ? 1 : 0.9)
                                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: player.playing)
                                .shadow(color: .black.opacity(0.16), radius: 20, y: 12)
                        }
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(current?.title ?? "未在播放").font(.title2.bold()).lineLimit(2)
                                Text(current?.artist ?? "选择一首歌曲").font(.title3).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if let current {
                                Button { library.toggleFavorite(current) } label: {
                                    Image(systemName: current.favorite ? "star.fill" : "star").frame(width: 44, height: 44)
                                }.buttonStyle(.plain).modifier(GlassControl())
                                    .accessibilityLabel(current.favorite ? "取消收藏" : "收藏")
                                    .sensoryFeedback(.selection, trigger: current.favorite)
                            }
                            Button { details = true } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                                .buttonStyle(.plain).modifier(GlassControl()).accessibilityLabel("歌曲信息")
                        }
                        if mode == 1 { lyricsPanel }
                        if mode == 2 { queuePanel }
                        transport
                        VolumeControl().frame(height: 36).accessibilityLabel("系统音量")
                        HStack {
                            Button { mode = mode == 1 ? 0 : 1 } label: {
                                Image(systemName: "quote.bubble").frame(width: 48, height: 44)
                                    .foregroundStyle(mode == 1 ? Color.orange : Color.primary)
                            }.modifier(GlassControl()).accessibilityLabel("显示歌词")
                            Spacer()
                            RoutePicker().frame(width: 48, height: 44).modifier(GlassControl()).accessibilityLabel("选择音频输出")
                            Spacer()
                            Button { mode = mode == 2 ? 0 : 2 } label: {
                                Image(systemName: "list.bullet").frame(width: 48, height: 44)
                                    .foregroundStyle(mode == 2 ? Color.orange : Color.primary)
                            }.modifier(GlassControl()).accessibilityLabel("显示播放队列")
                        }.buttonStyle(.plain)
                        Text(player.output).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(26).frame(maxWidth: 620).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("正在播放").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("收起播放器")
            } }
            .sheet(isPresented: $details) {
                NavigationStack {
                    List {
                        if let current {
                            LabeledContent("专辑", value: current.album)
                            LabeledContent("音源", value: current.specification)
                            LabeledContent("文件", value: current.relativePath ?? current.filename)
                            Text("高音质本地播放，声音经过 iOS 系统混音。文件格式和输出采样率都不表示逐位还原。").font(.caption).foregroundStyle(.secondary)
                        }
                    }.navigationTitle("歌曲信息").navigationBarTitleDisplayMode(.inline)
                }.presentationDetents([.medium]).presentationDragIndicator(.visible)
            }
        }.tint(.orange).presentationDragIndicator(.visible)
    }

    private var transport: some View {
        VStack(spacing: 12) {
            Slider(value: Binding(get: { scrubbing ? draft : min(playbackClock.position, max(current?.duration ?? 0, 0.01)) },
                set: { draft = $0 }), in: 0...max(current?.duration ?? 0, 0.01)) { editing in
                if editing { draft = playbackClock.position; scrubbing = true }
                else { player.seek(draft); scrubbing = false }
            }.accessibilityLabel("播放进度")
            HStack { Text(clock(scrubbing ? draft : playbackClock.position)); Spacer(); Text("−" + clock(max(0, (current?.duration ?? 0) - playbackClock.position))) }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle").foregroundStyle(player.shuffle ? Color.orange : Color.secondary).frame(width: 44, height: 44)
                }.accessibilityLabel("切换随机播放")
                Spacer()
                Button { player.skip(backwards: true) } label: { Image(systemName: "backward.fill").font(.title).frame(width: 44, height: 54) }.accessibilityLabel("上一首")
                Spacer()
                Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 44)).frame(width: 60, height: 64) }.accessibilityLabel(player.playing ? "暂停" : "播放")
                Spacer()
                Button { player.skip() } label: { Image(systemName: "forward.fill").font(.title).frame(width: 44, height: 54) }.accessibilityLabel("下一首")
                Spacer()
                Button {
                    switch player.repeatMode { case .off: player.repeatMode = .all; case .all: player.repeatMode = .one; case .one: player.repeatMode = .off }
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.orange).frame(width: 44, height: 44)
                }.accessibilityLabel(player.repeatMode == .one ? "单曲循环" : player.repeatMode == .all ? "列表循环" : "循环已关闭")
            }.buttonStyle(.plain).foregroundStyle(.primary)
        }
    }

    private var queuePanel: some View {
        VStack(alignment: .leading) {
            Text("播放队列").font(.headline)
            List {
                ForEach(player.queuedTracks) { track in
                    Button { player.load(track) } label: { SongRow(track: track, root: library.root, current: track.id == current?.id) }.buttonStyle(.plain)
                }.onDelete { player.removeQueue(at: $0) }.onMove { player.moveQueue(from: $0, to: $1) }
            }.listStyle(.plain).frame(height: 230).environment(\.editMode, .constant(.active)).scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var lyricsPanel: some View {
        if let text = current?.lyrics, !text.isEmpty {
            let lines = LyricsLine.parse(text)
            let active = lines.lastIndex { ($0.time ?? -.infinity) <= playbackClock.position }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Button { if let time = line.time { player.seek(time) } } label: {
                                Text(line.text).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(index == active || line.time == nil ? Color.primary : Color.secondary)
                            }.buttonStyle(.plain).id(index)
                        }
                    }.padding(.vertical)
                }.frame(height: 235)
                    .onChange(of: active) { _, value in if let value { withAnimation { proxy.scrollTo(value, anchor: .center) } } }
            }
        } else { ContentUnavailableView("暂无本地歌词", systemImage: "quote.bubble", description: Text("将同名 UTF-8 .lrc 文件放在音乐旁，重新扫描后显示。")) }
    }
}

struct GlassControl: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency { content.glassEffect(.regular.interactive(), in: Capsule()) }
        else { content.background(.regularMaterial, in: Capsule()) }
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
private struct VolumeControl: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { let view = MPVolumeView(); view.showsRouteButton = false; return view }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct LyricsLine: Equatable {
    var time: Double?
    var text: String
    static func parse(_ text: String) -> [Self] {
        let regex = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]"#)
        var result: [Self] = []
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            let cleaned = regex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length), withTemplate: "").trimmingCharacters(in: .whitespaces)
            if matches.isEmpty {
                if !cleaned.isEmpty && !cleaned.hasPrefix("[") { result.append(Self(time: nil, text: cleaned)) }
            } else {
                for match in matches {
                    if let minutes = Double(ns.substring(with: match.range(at: 1))), let seconds = Double(ns.substring(with: match.range(at: 2))) {
                        result.append(Self(time: minutes * 60 + seconds, text: cleaned.isEmpty ? "♪" : cleaned))
                    }
                }
            }
        }
        return result.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
    }
}
