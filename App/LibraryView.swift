import SwiftUI
import UniformTypeIdentifiers
import AVKit

struct LibraryView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    @State private var importing = false
    @State private var showPlayer = false
    @State private var query = ""
    @State private var favoritesOnly = false
    @State private var pendingDelete: Track?

    private var visible: [Track] {
        library.tracks.filter { track in
            (!favoritesOnly || track.favorite) && (query.isEmpty ||
                "\(track.title) \(track.artist) \(track.album)".localizedCaseInsensitiveContains(query))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("仅显示收藏", isOn: $favoritesOnly)
                    Text("\(library.tracks.count) 首歌曲 · 完全离线")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if visible.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "把喜欢的音乐带进来" : "未找到歌曲",
                        systemImage: "waveform",
                        description: Text("从文件导入 FLAC、ALAC、WAV 或 AIFF，随时离线聆听。"))
                }
                ForEach(visible) { track in
                    Button {
                        player.load(track)
                        showPlayer = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: player.current?.id == track.id ? "waveform" : "music.note")
                                .font(.title2).foregroundStyle(.mint).frame(width: 32)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(track.title).foregroundStyle(.primary).lineLimit(1)
                                Text("\(track.artist) · \(track.album)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(track.specification).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if track.favorite { Image(systemName: "heart.fill").foregroundStyle(.mint) }
                        }.padding(.vertical, 4)
                    }
                    .contextMenu {
                        Button(track.favorite ? "取消收藏" : "收藏", systemImage: "heart") { library.toggleFavorite(track) }
                        Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = track }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("删除", role: .destructive) { pendingDelete = track }
                    }
                    .swipeActions(edge: .leading) {
                        Button("收藏", systemImage: "heart") { library.toggleFavorite(track) }.tint(.mint)
                    }
                }
            }
            .navigationTitle("原音")
            .searchable(text: $query, prompt: "歌曲、艺术家或专辑")
            .toolbar {
                Button { importing = true } label: { Label("导入音乐", systemImage: "plus") }
                    .disabled(library.importing)
            }
            .overlay { if library.importing { ProgressView("正在导入…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
            .safeAreaInset(edge: .bottom) {
                if let current = player.current {
                    HStack {
                        Button { showPlayer = true } label: {
                            VStack(alignment: .leading) {
                                Text(current.title).lineLimit(1).font(.headline)
                                Text(current.artist).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Button { player.toggle() } label: {
                            Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title2)
                        }.accessibilityLabel(player.playing ? "暂停" : "播放").padding(.horizontal)
                        Button { player.skip() } label: { Image(systemName: "forward.end.fill") }
                            .accessibilityLabel("下一首")
                    }.padding().background(.regularMaterial)
                }
            }
            .sheet(isPresented: $showPlayer) { NowPlayingView(player: player) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await library.importFiles(urls) }
                case .failure(let error): library.errorMessage = error.localizedDescription
                }
            }
            .confirmationDialog("从资料库删除这首歌曲？", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible) {
                if let track = pendingDelete {
                    Button("删除 \(track.title)", role: .destructive) {
                        player.stopIfCurrent(track)
                        library.remove(track)
                        pendingDelete = nil
                    }
                }
            } message: { Text("仅删除 App 内的副本，原始文件将保留。") }
            .alert("无法完成操作", isPresented: Binding(
                get: { library.errorMessage != nil || player.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil; player.errorMessage = nil } }
            )) {
                Button("好") { library.errorMessage = nil; player.errorMessage = nil }
            } message: { Text(library.errorMessage ?? player.errorMessage ?? "") }
        }
    }
}

struct NowPlayingView: View {
    @ObservedObject var player: PlayerStore
    @State private var scrubbing = false
    @State private var draft: Double = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Image(systemName: "waveform.circle.fill")
                        .resizable().scaledToFit().frame(maxWidth: 240).foregroundStyle(.mint.gradient)
                        .padding(.top, 32).accessibilityHidden(true)
                    if let current = player.current {
                        VStack(spacing: 10) {
                            Text(current.title).font(.title2.bold()).multilineTextAlignment(.center)
                            Text(current.artist).foregroundStyle(.secondary)
                            Text(current.specification).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        VStack {
                            Slider(value: Binding(get: { scrubbing ? draft : player.position },
                                                  set: { draft = $0 }),
                                   in: 0...max(current.duration, 0.01)) { editing in
                                if editing { draft = player.position; scrubbing = true }
                                else { player.seek(draft); scrubbing = false }
                            }.accessibilityLabel("播放进度")
                            HStack {
                                Text(clock(scrubbing ? draft : player.position))
                                Spacer()
                                Text(clock(current.duration))
                            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 32) {
                        Button { player.shuffle.toggle() } label: {
                            Image(systemName: "shuffle").foregroundStyle(player.shuffle ? Color.mint : Color.secondary)
                        }.accessibilityLabel(player.shuffle ? "关闭随机播放" : "开启随机播放")
                        Button { player.skip(backwards: true) } label: { Image(systemName: "backward.end.fill") }.accessibilityLabel("上一首")
                        Button { player.toggle() } label: {
                            Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64))
                        }.accessibilityLabel(player.playing ? "暂停" : "播放")
                        Button { player.skip() } label: { Image(systemName: "forward.end.fill") }.accessibilityLabel("下一首")
                        Button { player.repeatAll.toggle() } label: {
                            Image(systemName: "repeat").foregroundStyle(player.repeatAll ? Color.mint : Color.secondary)
                        }.accessibilityLabel(player.repeatAll ? "关闭列表循环" : "开启列表循环")
                    }.font(.title3)
                    VStack(spacing: 8) {
                        Text(player.output).font(.caption)
                        Text("显示的是音源与系统输出规格，不代表逐位无损输出。")
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        RoutePicker().frame(width: 44, height: 44).accessibilityLabel("选择音频输出")
                    }
                }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.navigationTitle("正在播放").navigationBarTitleDisplayMode(.inline)
        }
    }

    private func clock(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, seconds)) : 0
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
