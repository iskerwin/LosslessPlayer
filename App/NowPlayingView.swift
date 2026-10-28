import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer
import CoreImage

/// Progress spans the volume row, including its two speaker icons.
enum PlayerControlMetrics {
    static let restingTrackHeight: CGFloat = 8
    static let activeTrackHeight: CGFloat = 16
    static let minimumHitHeight: CGFloat = 44
    static let volumeIconWidth: CGFloat = 28
    static let volumeIconSpacing: CGFloat = 10
    static let timestampGap: CGFloat = 6
    // Let timestamps overlap only the invisible lower portion of the hit area.
    static let timestampOverlap = (minimumHitHeight - activeTrackHeight) / 2 - timestampGap
}

/// Horizontal artwork swipe, the way Music changes tracks: swipe left for
/// the next track, right for the previous. Pure decision logic so the
/// thresholds stay testable. A swipe must travel 60pt and be clearly more
/// horizontal than vertical, so it never fights pull-down-to-dismiss.
enum ArtworkSwipe {
    enum Direction { case next, previous }
    static func direction(for translation: CGSize) -> Direction? {
        guard follows(translation), abs(translation.width) > 60 else { return nil }
        return translation.width < 0 ? .next : .previous
    }
    static func follows(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height) * 1.5
    }
}

struct NowPlayingView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    var onOpen: (LibraryRoute) -> Void
    var onDelete: (Track) -> Void
    /// The player is an overlay above the tabs, not a modal cover, so
    /// closing is the presenter's job (it also reverses the artwork morph).
    var onClose: () -> Void
    /// Downward drag distance in points, or 0 when the drag is no longer
    /// vertical. The presenter dims the library from this; it is not animated.
    var onPull: (CGFloat) -> Void
    /// The drag ended short of dismiss. The presenter springs the dim back.
    var onPullCancelled: () -> Void
    /// Shared-element morph with the mini player: when a namespace is
    /// wired, the stage artwork is the morph source while `morphActive`.
    var morphNamespace: Namespace.ID?
    var morphActive: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(library: LibraryStore, player: PlayerStore, onOpen: @escaping (LibraryRoute) -> Void = { _ in }, onDelete: @escaping (Track) -> Void = { _ in }, onClose: @escaping () -> Void = {}, onPull: @escaping (CGFloat) -> Void = { _ in }, onPullCancelled: @escaping () -> Void = {}, morphNamespace: Namespace.ID? = nil, morphActive: Bool = false) {
        self.library = library
        self.player = player
        self.onOpen = onOpen
        self.onDelete = onDelete
        self.onClose = onClose
        self.onPull = onPull
        self.onPullCancelled = onPullCancelled
        self.morphNamespace = morphNamespace
        self.morphActive = morphActive
    }

    private enum Panel { case artwork, lyrics, queue }
    @State private var panel = Panel.artwork
    @State private var details = false
    @State private var playlistTarget: Track?
    @GestureState private var dismissOffset: CGFloat = 0
    @GestureState private var artworkDrag: CGSize = .zero
    @State private var palette: [Color] = ArtworkColors.fallback.map { Color($0) }
    /// Blurred artwork texture for the backdrop. It swaps together with its
    /// filename key, so the crossfade animates the (image, key) pair and a
    /// stale texture never flashes under a new identity.
    @State private var backdropImage: UIImage?
    @State private var backdropKey: String?
    /// MPVolumeView and AVRoutePickerView are expensive to create; mounting
    /// them during the presentation's first frames drops the zoom. They
    /// mount once it has settled, into reserved frames of the same size.
    @State private var chromeReady = false
    /// Controls below the stage fade/slide in just behind the artwork's
    /// morph on open, staggered the way Music brings them in.
    @State private var entered = false
    /// Set the moment a drag releases past the dismiss threshold: the sheet
    /// is leaving, so the drag offsets must freeze instead of springing back
    /// to zero while the cover slides down (that double motion reads as a
    /// stutter). `frozenDismissY` holds the release position for the ride down.
    @State private var dismissing = false
    @State private var frozenDismissY: CGFloat = 0
    /// Direction of the most recent track change, so the artwork/title slide
    /// the way Music does: next slides in from the right, previous from the left.
    @State private var skipDirection: ArtworkSwipe.Direction = .next
    /// Parsed once per track. The playback clock must not re-run the regex
    /// on every tick, and the clock is observed only by the scrubber and
    /// the lyrics list so a position update does not rebuild the player.
    @State private var lyricLines: [LyricsLine] = []
    private var current: Track? { library.track(player.current?.id) }
    private var duration: Double {
        let duration = current?.duration ?? 0
        return duration.isFinite && duration > 0 ? duration : 0
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                if geometry.size.height < 600 || dynamicTypeSize.isAccessibilitySize {
                    ScrollView {
                        playerContent(stageHeight: min(260, max(120, geometry.size.width - 56)))
                    }
                } else {
                    playerContent(stageHeight: nil)
                }
            }
        }
        // The backdrop hangs as a background, never as a ZStack sibling:
        // as a sibling its scaled-to-fill image took part in the stack's
        // size negotiation, the root could size past the window, and the
        // 560-capped content column centered off-screen (the queue button
        // landed at x=395 on a ~393pt screen; XCUITest found no hit point).
        // Backgrounds are sized by the content, never the reverse.
        //
        // Opacity is on the expanded plate itself, then the drag offset
        // wraps the plate. An ignoresSafeArea background drawn outside the
        // fading view stays fully opaque until the player is removed, and
        // light mode snaps from that color to the white library.
        .background {
            ZStack {
                Color(white: 0.08)
                ArtworkBackdrop(colors: palette, image: backdropImage, imageKey: backdropKey)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: palette)
            }
            .ignoresSafeArea()
            .compositingGroup()
            .opacity(morphActive ? 1 : 0)
            .animation(reduceMotion ? .easeInOut(duration: 0.25) : LibraryView.playerSpring, value: morphActive)
        }
        .offset(y: reduceMotion ? 0 : dismissOffset + artworkPullY + frozenDismissY)
        // While a drag is live its value is non-zero and the offset follows
        // the finger 1:1 with no animation; a spring on the drag value made
        // the page trail the touch. The spring returns exactly when the
        // gesture state resets to zero on release, animating the snap-back.
        .animation(dismissing || reduceMotion || dismissOffset != 0 ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: dismissOffset)
        .animation(dismissing || reduceMotion || artworkDrag != .zero ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: artworkDrag)
        .foregroundStyle(.white)
        .tint(.white)
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-playing")
        // Presented as an overlay, not a cover: our drag owns dismissal
        // outright (past 90pt it closes via onClose and the morph reverses).
        .onAppear {
            refreshBackdrop()
            reloadLyrics()
        }
        .onChange(of: current?.artworkFilename) { _, _ in refreshBackdrop() }
        .onChange(of: current?.id) { _, _ in reloadLyrics() }
        .onChange(of: current?.lyrics) { _, _ in reloadLyrics() }
        .task {
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.9)) { entered = true }
            try? await Task.sleep(for: .milliseconds(290))
            chromeReady = true
        }
        .accessibilityAction(.escape) { onClose() }
        .sheet(item: $playlistTarget) { track in
            AddToPlaylistSheet(library: library, tracks: [track])
        }
        .sheet(isPresented: $details) { detailsSheet }
    }

    private func playerContent(stageHeight: CGFloat?) -> some View {
        VStack(spacing: 0) {
            Button { onClose() } label: {
                Capsule()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 60, height: 4)
                    .frame(width: 90, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起播放器")
            .highPriorityGesture(dismissGesture)
            stage
                .frame(height: stageHeight)
                .frame(minHeight: 120, maxHeight: stageHeight == nil ? .infinity : nil)
                .padding(.bottom, 24)
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    if panel != .queue { titleBlock }
                    scrubber
                    transport
                        .padding(.top, 18)
                }
                .fixedSize(horizontal: false, vertical: true)
                SystemVolumeBar(ready: chromeReady)
                    .padding(.top, 32)
                bottomRow
                    .padding(.top, 18)
            }
            // The stage (and its morphing artwork) is never offset; only
            // the control group staggers in behind it on open.
            .opacity(entered ? 1 : 0)
            .offset(y: entered || reduceMotion ? 0 : 16)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 12)
        .frame(maxWidth: 560, maxHeight: stageHeight == nil ? .infinity : nil)
        .frame(maxWidth: .infinity)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .updating($dismissOffset) { value, offset, _ in
                if value.translation.height > abs(value.translation.width) * 1.5 {
                    offset = max(0, value.translation.height)
                }
            }
            .onChanged { reportPull($0.translation) }
            .onEnded { value in
                if value.translation.height > 90,
                   value.translation.height > abs(value.translation.width) * 1.5 {
                    frozenDismissY = max(0, value.translation.height)
                    dismissing = true
                    onClose()
                } else {
                    onPullCancelled()
                }
            }
    }

    /// One drag gesture owns the artwork area and decides by dominant
    /// direction on release: mostly horizontal past 60pt skips, mostly down
    /// past 90pt dismisses. A single high-priority gesture cannot be
    /// starved by the zoom transition or by a second competing recognizer,
    /// which two cooperating drag gestures could not rule out.
    private var artworkGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .updating($artworkDrag) { value, state, _ in
                state = value.translation
            }
            .onChanged { reportPull($0.translation) }
            .onEnded { value in
                if let direction = ArtworkSwipe.direction(for: value.translation) {
                    skipDirection = direction
                    onPullCancelled()
                    if direction == .next { player.skip() } else { player.skip(backwards: true) }
                } else if value.translation.height > 90,
                          value.translation.height > abs(value.translation.width) * 1.5 {
                    frozenDismissY = max(0, value.translation.height)
                    dismissing = true
                    onClose()
                } else {
                    onPullCancelled()
                }
            }
    }

    /// Tell the library how far this drag has pulled the sheet down, so its
    /// dim can fade with the finger. Reduce Motion keeps the crossfade for
    /// the dismiss itself and does not scrub the dim mid-gesture.
    private func reportPull(_ translation: CGSize) {
        guard !reduceMotion else { return }
        if translation.height > abs(translation.width) * 1.5 {
            onPull(max(0, translation.height))
        } else {
            onPull(0)
        }
    }

    /// Vertical follow for the artwork drag: only the dominant-down part
    /// moves the whole sheet, mirroring the handle's pull.
    private var artworkPullY: CGFloat {
        artworkDrag.height > abs(artworkDrag.width) * 1.5 ? max(0, artworkDrag.height) : 0
    }

    /// Horizontal follow for the artwork drag while it is horizontal-dominant.
    private var artworkSwipeX: CGFloat {
        ArtworkSwipe.follows(artworkDrag) ? artworkDrag.width : 0
    }

    @ViewBuilder private var stage: some View {
        ZStack {
            if panel == .artwork {
                GeometryReader { geometry in
                    let side = max(0, min(geometry.size.width * 0.90, geometry.size.height * 0.9))
                    ArtworkView(track: current, root: library.root, size: side, placeholder: .neutral)
                        .id(current?.id)
                        .transition(artworkTransition)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
                        // Flatten the blur once, then scale the texture. A
                        // shadow inside an animating scale re-blurs every frame.
                        .compositingGroup()
                        .scaleEffect(player.playing ? 1 : 0.86)
                        .offset(x: reduceMotion ? 0 : artworkSwipeX)
                        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82), value: player.playing)
                        .animation(reduceMotion || artworkDrag != .zero ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: artworkDrag)
                        .modifier(ArtworkMorph(namespace: morphNamespace, active: morphActive))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("now-playing-artwork")
                .highPriorityGesture(artworkGesture)
                .transition(.opacity)
            } else if panel == .lyrics {
                lyricsPanel
                    .transition(.opacity)
            } else {
                queuePanel
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: panel)
        .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: current?.id)
    }

    /// While the morph is wired, the artwork crossfades on track changes:
    /// a move transition would fight the matched-geometry frame. Without
    /// a morph namespace (previews, fixtures) the slide below stays.
    private var artworkTransition: AnyTransition {
        morphNamespace == nil ? trackTransition : .opacity
    }

    /// Track-change transition, the way Music slides artwork: the incoming
    /// track enters from the skip direction, the outgoing one leaves the
    /// opposite way, both fading. Used by the artwork and the title block.
    private var trackTransition: AnyTransition {
        let incoming: Edge = skipDirection == .next ? .trailing : .leading
        let outgoing: Edge = skipDirection == .next ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: incoming).combined(with: .opacity),
            removal: .move(edge: outgoing).combined(with: .opacity))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current?.title ?? "未在播放")
                        .font(panel == .queue ? .headline : .title2.bold())
                        .foregroundStyle(.white)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .multilineTextAlignment(.leading)
                    if let current {
                        Button {
                            onOpen(.artist(current.primaryArtist))
                            onClose()
                        } label: {
                            Text(current.artist)
                                .font(panel == .queue ? .subheadline : .title3)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("选择一首歌曲").font(.title3).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .id(current?.id)
                .transition(trackTransition)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let current {
                    Button { library.toggleFavorite(current) } label: {
                        Image(systemName: current.favorite ? "star.fill" : "star")
                            .font(.system(size: 23, weight: .regular))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(current.favorite ? "取消收藏" : "收藏")
                    Menu {
                        Button("添加到歌单", systemImage: "text.badge.plus") { playlistTarget = current }
                        Button("前往专辑", systemImage: "music.note") {
                            onOpen(.album(current.albumID))
                            onClose()
                        }
                        Button("前往艺术家", systemImage: "music.mic") {
                            onOpen(.artist(current.primaryArtist))
                            onClose()
                        }
                        Button("歌曲信息", systemImage: "info.circle") { details = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("更多")
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: current?.id)
    }

    private var scrubber: some View {
        PlaybackScrubber(playbackClock: player.clock, duration: duration, trackID: current?.id) { player.seek($0) }
    }

    private var transport: some View {
        let symbol = player.playing ? "pause.fill" : "play.fill"
        return HStack {
            transportButton("backward.fill", label: "上一首", size: 34) { skipDirection = .previous; player.skip(backwards: true) }
            Spacer()
            transportButton(symbol, label: player.playing ? "暂停" : "播放", size: 44) { player.toggle() }
            Spacer()
            transportButton("forward.fill", label: "下一首", size: 34) { skipDirection = .next; player.skip() }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }

    private func transportButton(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .frame(width: 64, height: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }

    private var bottomRow: some View {
        HStack {
            bottomButton(panel == .lyrics ? "quote.bubble.fill" : "quote.bubble", label: "显示歌词") {
                panel = panel == .lyrics ? .artwork : .lyrics
            }
            Spacer()
            ZStack {
                if chromeReady {
                    RoutePicker()
                        .accessibilityLabel("选择音频输出")
                        .transition(.opacity)
                }
            }
            .frame(width: 48, height: 44)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: chromeReady)
            Spacer()
            bottomButton("list.bullet", label: "显示播放队列") {
                panel = panel == .queue ? .artwork : .queue
            }
        }
        .padding(.bottom, 4)
    }

    private func bottomButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 48, height: 44)
                .foregroundStyle(.white.opacity(panelSymbolActive(symbol) ? 1 : 0.92))
                .contentShape(Rectangle())
                .background {
                    if panelSymbolActive(symbol) {
                        Circle().fill(.white.opacity(0.3))
                    }
                }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(panelSymbolActive(symbol) ? .isSelected : [])
    }

    private func panelSymbolActive(_ symbol: String) -> Bool {
        (symbol.contains("quote") && panel == .lyrics) || (symbol.contains("list") && panel == .queue)
    }

    private var queuePanel: some View {
        let look = NowPlayingTransport.state(playing: player.playing, shuffle: player.shuffle, repeatMode: player.repeatMode)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ArtworkView(track: current, root: library.root, size: 72)
                titleBlock
            }
            HStack(spacing: 12) {
                queueModeButton("shuffle", label: "切换随机播放", active: look.shuffleHighlighted) { player.toggleShuffle() }
                    .accessibilityValue(look.shuffleHighlighted ? "已开启" : "已关闭")
                queueModeButton(look.repeatSymbol, label: look.repeatAccessibility, active: look.repeatHighlighted) { player.cycleRepeat() }
            }
            Text("接下来").font(.headline).padding(.top, 4)
            if player.upcomingTracks.isEmpty {
                Text("队列已播放完毕").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List {
                    ForEach(player.upcomingTracks) { track in
                        Button { player.load(track) } label: {
                            SongRow(track: track, root: library.root, emphasis: .white)
                                .equatable()
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .contextMenu {
                            Button("从队列移除", systemImage: "minus.circle", role: .destructive) {
                                if let index = player.upcomingTracks.firstIndex(where: { $0.id == track.id }) {
                                    player.removeUpcoming(at: IndexSet(integer: index))
                                }
                            }
                        }
                    }
                    .onMove { player.moveUpcoming(from: $0, to: $1) }
                }
                .environment(\.editMode, .constant(.active))
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 0, for: .scrollContent)
                .accessibilityIdentifier("upcoming-queue")
            }
        }
        .padding(.top, 4)
    }

    private func queueModeButton(_ symbol: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(active ? Color(white: 0.18) : Color.white)
                .background(active ? Color.white.opacity(0.9) : Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder private var lyricsPanel: some View {
        if lyricLines.isEmpty {
            ContentUnavailableView("暂无本地歌词", systemImage: "quote.bubble", description: Text("将同名 UTF-8 .lrc 文件放在音乐旁，重新扫描后显示。"))
        } else {
            PlaybackLyrics(clock: player.clock, lines: lyricLines) { player.seek($0) }
        }
    }

    private func reloadLyrics() {
        guard let text = current?.lyrics, current?.hasLyrics == true else {
            lyricLines = []
            return
        }
        lyricLines = LyricsLine.parse(text)
    }

    private var detailsSheet: some View {
        NavigationStack {
            List {
                if let current {
                    LabeledContent("标记", value: current.qualityBadge)
                    LabeledContent("位深", value: current.bitDepth > 0 ? "\(current.bitDepth)-bit" : "未知")
                    LabeledContent("采样率", value: String(format: "%.1f kHz", current.sampleRate / 1000))
                    LabeledContent("格式", value: (current.filename as NSString).pathExtension.uppercased())
                    LabeledContent("输出", value: player.output.isEmpty ? "未知" : player.output)
                    LabeledContent("播放路径", value: player.pathAssessment?.title ?? "未知")
                    LabeledContent("文件", value: current.relativePath ?? current.filename)
                    Text(player.pathAssessment?.detail ?? "高音质本地播放，声音经过 iOS 系统混音。文件格式和输出采样率都不表示逐位还原。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("歌曲信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { details = false } } }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var handlers: SongHandlers {
        SongHandlers(
            play: { player.load($0) },
            favorite: { library.toggleFavorite($0) },
            playlist: { playlistTarget = $0 },
            playNext: { player.enqueue([$0], next: true) },
            addToQueue: { player.enqueue([$0], next: false) },
            album: { onOpen(.album($0.albumID)); onClose() },
            artist: { onOpen(.artist($0.primaryArtist)); onClose() },
            lyrics: { _ in panel = .lyrics },
            delete: onDelete
        )
    }

    /// Backdrop data (palette + blurred texture) is computed off the main
    /// thread from a downscaled copy and cached per artwork file. The old
    /// version ran Core Image over the full-resolution image on the main
    /// thread, inside the presentation's first frames.
    private func refreshBackdrop() {
        guard let filename = current?.artworkFilename else {
            palette = ArtworkColors.fallback.map { Color($0) }
            backdropImage = nil
            backdropKey = nil
            return
        }
        if let cached = ArtworkAnalysisCache.shared.analysis(for: filename) {
            applyBackdrop(cached, key: filename)
            return
        }
        let url = library.root.appendingPathComponent(filename)
        Task { @MainActor in
            let ready = await Task.detached(priority: .userInitiated) { () -> Bool in
                guard let image = ArtworkCache.shared.image(at: url, maxPixel: 160) else { return false }
                ArtworkAnalysisCache.shared.store(ArtworkAnalysis.make(from: image), for: filename)
                return true
            }.value
            guard ready, current?.artworkFilename == filename,
                  let analysis = ArtworkAnalysisCache.shared.analysis(for: filename) else { return }
            applyBackdrop(analysis, key: filename)
        }
    }

    private func applyBackdrop(_ analysis: ArtworkAnalysis, key: String) {
        palette = analysis.palette.map { Color(uiColor: $0) }
        backdropImage = analysis.backdrop
        backdropKey = key
    }
}

/// Observes the playback clock so the rest of the player does not rebuild
/// every half second.
private struct PlaybackScrubber: View {
    @ObservedObject var playbackClock: PlaybackClock
    var duration: Double
    var trackID: UUID?
    var seek: (Double) -> Void
    @State private var scrubbing = false
    @State private var draft: Double = 0

    private var shown: Double { scrubbing ? draft : min(playbackClock.position, duration) }

    var body: some View {
        VStack(spacing: -PlayerControlMetrics.timestampOverlap) {
            ThinScrubber(value: Binding(
                get: { shown },
                set: { draft = $0 }
            ), range: 0...(duration > 0 ? duration : 1), onEditingChanged: { editing in
                if editing {
                    draft = playbackClock.position
                    scrubbing = true
                } else {
                    if scrubbing, duration > 0 { seek(draft) }
                    scrubbing = false
                }
            }, onCancel: { scrubbing = false })
            .id(trackID)
            .disabled(duration == 0)
            .accessibilityLabel("播放进度")
            .accessibilityValue(duration > 0 ? "\(clock(shown))，共 \(clock(duration))" : "时长未知")
            .accessibilityIdentifier("playback-progress")
            HStack {
                Text(duration > 0 ? clock(shown) : "--:--")
                Spacer()
                Text(duration > 0 ? "−" + clock(max(0, duration - shown)) : "--:--")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
            .allowsHitTesting(false)
        }
        .onChange(of: trackID) { _, _ in scrubbing = false }
    }
}

private struct PlaybackLyrics: View {
    @ObservedObject var clock: PlaybackClock
    var lines: [LyricsLine]
    var seek: (Double) -> Void

    var body: some View {
        LyricsScroll(lines: lines, position: clock.position, seek: seek)
    }
}

struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

enum ScrubberMap {
    static func fraction(value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span.isFinite, span > 0, range.lowerBound.isFinite, value.isFinite else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    static func value(x: CGFloat, width: CGFloat, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard width.isFinite, x.isFinite, width > 0, span.isFinite, span > 0 else { return range.lowerBound }
        let fraction = min(1, max(0, Double(x / width)))
        return range.lowerBound + fraction * span
    }
}

struct ThinScrubber: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onCancel: () -> Void = {}
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @GestureState private var fingerDown = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = ScrubberMap.fraction(value: value, in: range)
            let thickness = dragging ? PlayerControlMetrics.activeTrackHeight : PlayerControlMetrics.restingTrackHeight
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(contrast == .increased ? 0.5 : 0.28)).frame(height: thickness)
                Capsule().fill(Color.white).frame(width: width * fraction, height: thickness)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($fingerDown) { _, state, _ in state = true }
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if !dragging {
                            dragging = true
                            onEditingChanged(true)
                        }
                        value = ScrubberMap.value(x: gesture.location.x, width: width, in: range)
                    }
                    .onEnded { _ in
                        guard dragging else { return }
                        dragging = false
                        if isEnabled { onEditingChanged(false) }
                        else { onCancel() }
                    }
            )
        }
        .frame(height: PlayerControlMetrics.minimumHitHeight)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: dragging)
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let step = min(10, range.upperBound - range.lowerBound)
            let delta: Double
            switch direction {
            case .increment: delta = step
            case .decrement: delta = -step
            @unknown default: return
            }
            let next = min(range.upperBound, max(range.lowerBound, value + delta))
            onEditingChanged(true)
            value = next
            onEditingChanged(false)
        }
        .onChange(of: fingerDown) { _, active in
            if !active && dragging {
                dragging = false
                onCancel()
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled && dragging {
                dragging = false
                onCancel()
            }
        }
        .onDisappear {
            if dragging { onCancel() }
        }
    }
}

enum ArtworkColors {
    static let fallback: [UIColor] = [
        UIColor(red: 0.08, green: 0.12, blue: 0.20, alpha: 1),
        UIColor(red: 0.14, green: 0.18, blue: 0.30, alpha: 1),
        UIColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1),
        UIColor(red: 0.11, green: 0.15, blue: 0.24, alpha: 1)
    ]

    static func palette(from image: UIImage?) -> [UIColor] {
        guard let image, let ci = CIImage(image: image) else { return fallback }
        let extent = ci.extent.integral
        guard extent.width > 1, extent.height > 1 else { return fallback }
        let regions = [
            CGRect(x: extent.minX, y: extent.midY, width: extent.width / 2, height: extent.height / 2),
            CGRect(x: extent.midX, y: extent.midY, width: extent.width / 2, height: extent.height / 2),
            CGRect(x: extent.minX, y: extent.minY, width: extent.width / 2, height: extent.height / 2),
            CGRect(x: extent.midX, y: extent.minY, width: extent.width / 2, height: extent.height / 2)
        ]
        let colors = regions.compactMap { average(ci, rect: $0) }.map(darkened)
        return colors.count == 4 ? colors : fallback
    }

    static func darkened(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return UIColor(white: 0.12, alpha: 1)
        }
        return UIColor(hue: hue, saturation: min(0.48, saturation * 0.65), brightness: min(0.36, max(0.10, brightness * 0.60)), alpha: 1)
    }

    /// One shared context: creating a CIContext per region per call was a
    /// visible part of the old main-thread cost.
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    private static func average(_ image: CIImage, rect: CGRect) -> UIColor? {
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return UIColor(red: CGFloat(bitmap[0]) / 255, green: CGFloat(bitmap[1]) / 255, blue: CGFloat(bitmap[2]) / 255, alpha: 1)
    }
}

/// Everything the backdrop needs from one artwork, computed once per file
/// off the main thread: the four-quadrant palette and a small texture that
/// reads as a blur once stretched full-screen. A static texture replaces
/// the full-screen mesh gradient, whose per-frame rendering made the
/// presentation drop frames; a textured backdrop is also what Music
/// composites behind its player.
struct ArtworkAnalysis {
    var palette: [UIColor]
    var backdrop: UIImage?

    static func make(from image: UIImage) -> ArtworkAnalysis {
        let small = image.downscaled(maxPixel: 96)
        return ArtworkAnalysis(palette: ArtworkColors.palette(from: small),
                               backdrop: small.downscaled(maxPixel: 40))
    }
}

final class ArtworkAnalysisCache {
    static let shared = ArtworkAnalysisCache()
    private let cache = NSCache<NSString, ArtworkAnalysisBox>()

    private init() { cache.countLimit = 40 }

    func analysis(for filename: String) -> ArtworkAnalysis? {
        cache.object(forKey: filename as NSString)?.analysis
    }

    func store(_ analysis: ArtworkAnalysis, for filename: String) {
        cache.setObject(ArtworkAnalysisBox(analysis), forKey: filename as NSString)
    }
}

private final class ArtworkAnalysisBox: NSObject {
    let analysis: ArtworkAnalysis
    init(_ analysis: ArtworkAnalysis) { self.analysis = analysis }
}

extension UIImage {
    /// Aspect-fit copy whose longest side is at most `maxPixel` points at
    /// scale 1; returns `self` when already small enough.
    func downscaled(maxPixel: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxPixel, longest > 0 else { return self }
        let ratio = maxPixel / longest
        let target = CGSize(width: max(1, (size.width * ratio).rounded()),
                            height: max(1, (size.height * ratio).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// Matched-geometry link between the mini player's artwork and the stage
/// artwork: one shared element grows/shrinks between the two frames, the
/// way Music's thumbnail becomes the full cover. Inert without a namespace.
private struct ArtworkMorph: ViewModifier {
    var namespace: Namespace.ID?
    var active: Bool

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "playerArtwork", in: namespace, isSource: active)
        } else {
            content
        }
    }
}

struct ArtworkBackdrop: View {
    var colors: [Color]
    var image: UIImage? = nil
    var imageKey: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(colors: colors.isEmpty ? ArtworkColors.fallback.map { Color(uiColor: $0) } : colors,
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .id(imageKey)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            ZStack {
                Color.black.opacity(image == nil ? 0 : 0.22)
                LinearGradient(colors: [.white.opacity(0.06), .clear, .black.opacity(0.32)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: imageKey)
    }
}

struct LyricsScroll: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lines: [LyricsLine]
    var position: Double?
    var seek: (Double) -> Void

    var body: some View {
        let active = position.flatMap { value in lines.lastIndex { ($0.time ?? -.infinity) <= value } }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        LyricLineText(
                            text: line.text,
                            prominent: line.time == nil || index == active,
                            time: line.time,
                            seek: seek
                        )
                        .equatable()
                        .id(index)
                    }
                }
                .padding(.vertical)
            }
            .onChange(of: active) { _, value in
                if let value {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        proxy.scrollTo(value, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct LyricLineText: View, Equatable {
    var text: String
    var prominent: Bool
    var time: Double?
    var seek: (Double) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: LyricLineText, rhs: LyricLineText) -> Bool {
        lhs.text == rhs.text && lhs.prominent == rhs.prominent && lhs.time == rhs.time
    }

    var body: some View {
        Button { if let time { seek(time) } } label: {
            Text(text)
                .font(.title3.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(prominent ? Color.white : Color.white.opacity(0.45))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: prominent)
        }
        .buttonStyle(.plain)
    }
}

struct LyricsReader: View {
    @ObservedObject var player: PlayerStore
    let track: Track
    @State private var lines: [LyricsLine]
    @Environment(\.dismiss) private var dismiss

    init(player: PlayerStore, track: Track) {
        self.player = player
        self.track = track
        _lines = State(initialValue: track.hasLyrics ? LyricsLine.parse(track.lyrics ?? "") : [])
    }

    var body: some View {
        NavigationStack {
            Group {
                if track.hasLyrics {
                    LyricsReaderBody(player: player, track: track, lines: lines)
                } else {
                    ContentUnavailableView("暂无歌词", systemImage: "quote.bubble", description: Text("这首歌没有内嵌或同名的歌词。"))
                }
            }
            .navigationTitle("歌词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// Clock observer for the reader. Parsing stays in `LyricsReader`, which does
/// not subscribe to the half-second position.
private struct LyricsReaderBody: View {
    @ObservedObject var player: PlayerStore
    @ObservedObject private var clock: PlaybackClock
    let track: Track
    let lines: [LyricsLine]

    init(player: PlayerStore, track: Track, lines: [LyricsLine]) {
        self.player = player
        self.track = track
        self.lines = lines
        _clock = ObservedObject(wrappedValue: player.clock)
    }

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        LyricsScroll(lines: lines, position: isCurrent ? clock.position : nil) { time in
            if isCurrent || player.queueIDs.contains(track.id) {
                if isCurrent { player.seek(time) }
                else { player.load(track, at: time, keepTransport: true) }
            } else {
                player.load(track, at: time)
            }
        }
    }
}

struct SystemVolumeBar: View {
    /// False only during the presentation's first moments: the reserved
    /// frame keeps the layout identical while the native view is deferred.
    var ready: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: PlayerControlMetrics.volumeIconSpacing) {
            VolumeSpeaker(symbol: "speaker.fill", alignment: .leading)
            Group {
                if ready {
                    NativeVolumeView()
                        .transition(.opacity)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: PlayerControlMetrics.minimumHitHeight)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: ready)
            VolumeSpeaker(symbol: "speaker.wave.3.fill", alignment: .trailing)
        }
        .foregroundStyle(.white.opacity(0.6))
    }
}

private struct VolumeSpeaker: View {
    let symbol: String
    let alignment: Alignment

    var body: some View {
        let image = UIImage(systemName: symbol) ?? UIImage()
        let height = PlayerControlMetrics.activeTrackHeight
        let width = height * image.size.width / max(1, image.size.height)
        Image(uiImage: image)
            .resizable()
            .renderingMode(.template)
            .frame(width: width, height: height)
            .frame(width: PlayerControlMetrics.volumeIconWidth,
                   height: PlayerControlMetrics.minimumHitHeight, alignment: alignment)
            .accessibilityHidden(true)
    }
}

/// Let the system own volume changes, accessibility, hardware buttons, and fixed-volume routes.
private struct NativeVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MusicVolumeView { MusicVolumeView(frame: .zero) }
    func updateUIView(_ view: MusicVolumeView, context: Context) { }
}

/// Public MPVolumeView appearance APIs retain native volume, hardware-key and
/// route behavior. Transparent thumbs keep the slider's native touch handling.
private final class MusicVolumeView: MPVolumeView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        showsRouteButton = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        let transparent = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        for state in [UIControl.State.normal, .highlighted, .disabled] {
            let height = state == .highlighted ? PlayerControlMetrics.activeTrackHeight : PlayerControlMetrics.restingTrackHeight
            setVolumeThumbImage(transparent, for: state)
            setMinimumVolumeSliderImage(Self.track(height: height, alpha: 0.65), for: state)
            setMaximumVolumeSliderImage(Self.track(height: height, alpha: 0.28), for: state)
        }
        accessibilityLabel = "系统音量"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func volumeSliderRect(forBounds bounds: CGRect) -> CGRect {
        let height = PlayerControlMetrics.activeTrackHeight
        return CGRect(x: 0, y: bounds.midY - height / 2, width: bounds.width, height: height)
    }

    private static func track(height: CGFloat, alpha: CGFloat) -> UIImage {
        let canvasHeight = PlayerControlMetrics.activeTrackHeight
        let width = canvasHeight * 2
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: canvasHeight)).image { _ in
            UIColor.white.withAlphaComponent(alpha).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: (canvasHeight - height) / 2, width: width, height: height), cornerRadius: height / 2).fill()
        }.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: width / 2 - 1, bottom: 0, right: width / 2 - 1), resizingMode: .stretch)
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.65)
        view.activeTintColor = .white
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = .white
        uiView.activeTintColor = .white
    }
}

struct LyricsLine: Equatable {
    var time: Double?
    var text: String
    static func parse(_ text: String) -> [Self] {
        let regex = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]"#)
        let offsetRegex = try! NSRegularExpression(pattern: #"\[offset:[ \t]*([+-]?[0-9]+)\]"#, options: .caseInsensitive)
        let nsText = text as NSString
        var offsetMilliseconds = 0.0
        // Scan the whole file first: the last valid offset applies to every timestamp.
        for match in offsetRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            if let value = Double(nsText.substring(with: match.range(at: 1))), value.isFinite {
                offsetMilliseconds = value
            }
        }
        // LRC offset is milliseconds: parsed time = timestamp - offset / 1000.
        // Positive means earlier: [offset:+500] + [00:10.00] -> 9.5 seconds.
        // Negative means later: [offset:-1000] + [00:10.00] -> 11.0 seconds.
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
                        let time = max(0, minutes * 60 + seconds - offsetMilliseconds / 1000)
                        result.append(Self(time: time, text: cleaned.isEmpty ? "♪" : cleaned))
                    }
                }
            }
        }
        return result.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
    }
}
