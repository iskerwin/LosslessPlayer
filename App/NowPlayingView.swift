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

/// Header appearance mapping, independent of PlayerCard presentation.
/// The queue button selects the expanded or compact endpoint.
enum PlayerScrollMorph {
    static let compactHeight: CGFloat = 88
    static let queueRevealStart: CGFloat = 0.7
    static let interactionThreshold: CGFloat = 0.98

    static func progress(offset: CGFloat, travel: CGFloat) -> CGFloat {
        guard travel > 0 else { return 0 }
        return min(1, max(0, offset / travel))
    }

    static func state(progress: CGFloat, largeArtwork: CGFloat, reduceMotion: Bool) -> State {
        let p = min(1, max(0, progress))
        return State(largeTitleOpacity: Double(1 - p), compactTitleOpacity: Double(p),
                     queueOpacity: Double(min(1, max(0, (p - queueRevealStart) / (1 - queueRevealStart)))),
                     queueInteractive: p >= interactionThreshold,
                     artworkSide: reduceMotion ? largeArtwork : largeArtwork + (72 - largeArtwork) * p,
                     artworkTravel: reduceMotion ? 0 : p,
                     largeArtworkOpacity: reduceMotion ? Double(1 - p) : 1,
                     compactArtworkOpacity: reduceMotion ? Double(p) : 0)
    }

    struct State {
        var largeTitleOpacity: Double
        var compactTitleOpacity: Double
        var queueOpacity: Double
        var queueInteractive: Bool
        var artworkSide: CGFloat
        var artworkTravel: CGFloat
        var largeArtworkOpacity: Double
        var compactArtworkOpacity: Double
    }
}

/// SwiftUI move destinations are insertion slots in the original collection.
/// A downward hover inserts after the target; an upward hover inserts before it.
enum QueueDropMapping {
    static func destination(source: Int, target: Int, count: Int) -> Int? {
        guard count > 0, (0..<count).contains(source), (0..<count).contains(target),
              source != target else { return nil }
        return target > source ? target + 1 : target
    }

    static func offset(index: Int, source: Int, target: Int, rowHeight: CGFloat) -> CGFloat {
        if source < target, index > source, index <= target { return -rowHeight }
        if target < source, index >= target, index < source { return rowHeight }
        return 0
    }
}

private struct QueueRowDrag {
    let ids: [UUID]
    let source: Int
    let frames: [UUID: CGRect]
    var target: Int
    var translation: CGSize

    var id: UUID { ids[source] }
    var frame: CGRect { frames[id] ?? .zero }
}

/// A pan beginning on this handle belongs to reordering. UIKit delivers end
/// and cancellation directly, without an NSItemProvider / per-row drop handoff.
private struct QueueDragHandle: UIViewRepresentable {
    var lifted: Bool
    var onPan: (UIGestureRecognizer.State, CGPoint, CGSize) -> Void

    func makeUIView(context: Context) -> HandleView { HandleView(onPan: onPan) }
    func updateUIView(_ view: HandleView, context: Context) {
        view.onPan = onPan
        // Keep the gesture-owning UIView visible for the entire touch sequence.
        view.icon.isHidden = lifted
    }
    static func dismantleUIView(_ view: HandleView, coordinator: ()) {
        view.cancel()
    }

    final class HandleView: UIView, UIGestureRecognizerDelegate {
        var onPan: (UIGestureRecognizer.State, CGPoint, CGSize) -> Void
        let icon = UIImageView(image: UIImage(systemName: "line.3.horizontal"))
        private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned))

        init(onPan: @escaping (UIGestureRecognizer.State, CGPoint, CGSize) -> Void) {
            self.onPan = onPan
            super.init(frame: .zero)
            icon.tintColor = UIColor.white.withAlphaComponent(0.6)
            icon.contentMode = .scaleAspectFit
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 20),
                icon.heightAnchor.constraint(equalToConstant: 20)
            ])
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            addGestureRecognizer(pan)
            isAccessibilityElement = true
            accessibilityLabel = "调整播放顺序"
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        // Dynamic failure priority works across SwiftUI's scroll view hierarchy
        // and only participates for touches that actually begin on this handle.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }

        @objc private func panned() {
            let translation = pan.translation(in: nil)
            onPan(pan.state, pan.location(in: nil),
                  CGSize(width: translation.x, height: translation.y))
        }

        func cancel() {
            if pan.state == .began || pan.state == .changed {
                pan.isEnabled = false
                pan.isEnabled = true
            }
        }
    }
}

struct NowPlayingView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    var onOpen: (LibraryRoute) -> Void
    var onDelete: (Track) -> Void
    /// The containing card owns all expand/collapse geometry and animation.
    var onClose: () -> Void
    var onPull: (CGFloat) -> Void
    var onPullCancelled: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var titleHeight: CGFloat = 72
    @ScaledMetric(relativeTo: .headline) private var compactHeaderHeight: CGFloat = PlayerScrollMorph.compactHeight

    init(library: LibraryStore, player: PlayerStore, onOpen: @escaping (LibraryRoute) -> Void = { _ in }, onDelete: @escaping (Track) -> Void = { _ in }, onClose: @escaping () -> Void = {}, onPull: @escaping (CGFloat) -> Void = { _ in }, onPullCancelled: @escaping () -> Void = {}) {
        self.library = library
        self.player = player
        self.onOpen = onOpen
        self.onDelete = onDelete
        self.onClose = onClose
        self.onPull = onPull
        self.onPullCancelled = onPullCancelled
    }

    private enum Panel { case artwork, lyrics }
    @State private var panel = Panel.artwork
    @State private var queueVisible = false
    @State private var queueRowFrames: [UUID: CGRect] = [:]
    @State private var queueDrag: QueueRowDrag?
    @State private var details = false
    @State private var playlistTarget: Track?
    @GestureState private var artworkDrag: CGSize = .zero
    /// MPVolumeView and AVRoutePickerView are expensive to create; mounting
    /// them during the presentation's first frames drops the zoom. They
    /// mount once it has settled, into reserved frames of the same size.
    @State private var chromeReady = false
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
                        playerContent(stageHeight: max(titleHeight + compactHeaderHeight,
                            min(260, max(120, geometry.size.width - 56))))
                    }
                } else {
                    playerContent(stageHeight: nil)
                }
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .statusBarHidden(false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-playing")
        // The gesture owns the 90pt dismissal decision; the card owns motion.
        .onAppear {
            reloadLyrics()
        }
        .onChange(of: current?.id) { _, _ in reloadLyrics() }
        .onChange(of: current?.lyrics) { _, _ in reloadLyrics() }
        .onChange(of: player.upcomingTracks.map(\.id)) { _, _ in queueDrag = nil }
        .onChange(of: panel) { _, _ in queueDrag = nil }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { queueDrag = nil }
        }
        .onChange(of: queueVisible) { _, interactive in
            if !interactive { queueDrag = nil }
        }
        .onDisappear { queueDrag = nil }
        .task {
            try? await Task.sleep(for: .milliseconds(350))
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
            Group {
                if panel == .lyrics {
                    stage.gesture(TapGesture().onEnded { })
                } else {
                    artworkStage.transition(.opacity)
                }
            }
                .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: panel)
                .frame(height: stageHeight)
                .frame(minHeight: 120, maxHeight: stageHeight == nil ? .infinity : nil)
                .padding(.bottom, 24)
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    if panel == .lyrics { titleBlock }
                    scrubber
                    transport
                        .padding(.top, 18)
                }
                .fixedSize(horizontal: false, vertical: true)
                // Keep native volume touches inside the control, including its icons.
                SystemVolumeBar(ready: chromeReady)
                    .gesture(TapGesture().onEnded { })
                    .padding(.top, 32)
                bottomRow
                    .padding(.top, 18)
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 12)
        .frame(maxWidth: 560, maxHeight: stageHeight == nil ? .infinity : nil)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // Ordinary priority lets child buttons and sliders own their taps.
        .gesture(TapGesture().onEnded { onClose() })
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onChanged { reportPull($0.translation) }
            .onEnded { value in
                if value.translation.height > 90,
                   value.translation.height > abs(value.translation.width) * 1.5 {
                    onClose()
                } else {
                    onPullCancelled()
                }
            }
    }

    /// Only the header owns skip/pull gestures; queue scrolling stays native.
    private var artworkGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .updating($artworkDrag) { value, state, _ in
                state = value.translation
            }
            .onChanged { value in
                reportPull(value.translation)
            }
            .onEnded { value in
                if let direction = ArtworkSwipe.direction(for: value.translation) {
                    skipDirection = direction
                    onPullCancelled()
                    if direction == .next { player.skip() } else { player.skip(backwards: true) }
                } else if value.translation.height > 90,
                          value.translation.height > abs(value.translation.width) * 1.5 {
                    onClose()
                } else {
                    onPullCancelled()
                }
            }
    }

    /// The presenter converts vertical points directly into card progress.
    private func reportPull(_ translation: CGSize) {
        guard !reduceMotion else { return }
        if translation.height > abs(translation.width) * 1.5 {
            onPull(max(0, translation.height))
        } else {
            onPull(0)
        }
    }

    /// Horizontal follow for the artwork drag while it is horizontal-dominant.
    private var artworkSwipeX: CGFloat {
        ArtworkSwipe.follows(artworkDrag) ? artworkDrag.width : 0
    }

    private var stage: some View {
        lyricsPanel
            .transition(.opacity)
    }

    /// Queue visibility has one source: the bottom-right button. The artwork
    /// endpoint has no scroll container or offscreen queue to reveal by swiping.
    private var artworkStage: some View {
        GeometryReader { geometry in
            let look = PlayerScrollMorph.state(progress: queueVisible ? 1 : 0,
                largeArtwork: max(0, min(geometry.size.width * 0.9,
                    (geometry.size.height - titleHeight - 24) * 0.9)),
                reduceMotion: reduceMotion)
            VStack(spacing: 0) {
                morphHeader(size: geometry.size, look: look)
                if queueVisible {
                    ScrollView {
                        queuePanel
                    }
                    .scrollIndicators(.hidden)
                    // Fade the cut-off row into the scrubber gap instead of a hard
                    // clip. A mask changes only drawing, not hit testing or AX.
                    .mask {
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 24)
                        }
                    }
                    .allowsHitTesting(queueVisible)
                    .accessibilityHidden(!queueVisible)
                    .accessibilityIdentifier("now-playing-queue-scroll")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: queueVisible)
        }
    }

    private func morphHeader(size: CGSize, look: PlayerScrollMorph.State) -> some View {
        let largeSide = max(0, min(size.width * 0.9, (size.height - titleHeight - 24) * 0.9))
        let origin = CGPoint(x: (size.width - largeSide) / 2,
                             y: max(0, (size.height - titleHeight - 24 - largeSide) / 2))
        let t = look.artworkTravel
        return ZStack(alignment: .topLeading) {
            ArtworkView(track: current, root: library.root, size: look.artworkSide, placeholder: .neutral)
                .id(current?.id)
                .transition(artworkTransition)
                .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: current?.id)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
                .compositingGroup()
                .scaleEffect(player.playing ? 1 : 0.86)
                .animation(reduceMotion || artworkDrag != .zero ? nil : .spring(response: 0.35, dampingFraction: 0.9)) { content in
                    content.offset(x: reduceMotion ? 0 : artworkSwipeX)
                }
                .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82), value: player.playing)
                .offset(x: origin.x * (1 - t), y: origin.y * (1 - t))
                .opacity(look.largeArtworkOpacity)
                .allowsHitTesting(look.largeArtworkOpacity >= 0.5)
                .accessibilityHidden(look.largeArtworkOpacity < 0.5)
            if reduceMotion {
                ArtworkView(track: current, root: library.root, size: 72, placeholder: .neutral)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .opacity(look.compactArtworkOpacity)
                    .allowsHitTesting(look.compactArtworkOpacity >= 0.5)
                    .accessibilityHidden(true)
            }
            titleBlock(compact: false)
                .offset(y: max(0, size.height - titleHeight))
                .opacity(look.largeTitleOpacity)
                .allowsHitTesting(look.largeTitleOpacity > 0.5)
                .accessibilityHidden(look.largeTitleOpacity <= 0.5)
            titleBlock(compact: true)
                .padding(.leading, 84)
                .frame(minHeight: 72)
                .opacity(look.compactTitleOpacity)
                .allowsHitTesting(look.compactTitleOpacity >= 0.5)
                .accessibilityHidden(look.compactTitleOpacity < 0.5)
        }
        .frame(width: size.width, height: queueVisible ? compactHeaderHeight : size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-playing-artwork")
        // Tap dismissal and the 16pt directional drag recognize separately.
        .simultaneousGesture(artworkGesture)
    }

    private var artworkTransition: AnyTransition { .opacity }

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

    private var titleBlock: some View { titleBlock(compact: false) }

    /// File quality at a glance; the full playback path stays in 歌曲信息.
    private func qualityBadge(_ track: Track) -> some View {
        Button { details = true } label: {
            Text(track.qualityBadge)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.16), in: Capsule())
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("音质 \(track.qualityBadge)")
        .accessibilityHint("显示歌曲信息")
        .accessibilityIdentifier("quality-badge")
    }

    private func titleBlock(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current?.title ?? "未在播放")
                        .font(compact ? .headline : .title2.bold())
                        .foregroundStyle(.white)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .multilineTextAlignment(.leading)
                    if let current {
                        HStack(spacing: 8) {
                            Button {
                                onOpen(.artist(current.primaryArtist))
                                onClose()
                            } label: {
                                Text(current.artist)
                                    .font(compact ? .subheadline : .title3)
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            // Beside the artist, not on its own row, so the title
                            // block keeps the height the artwork stage reserves.
                            if !compact { qualityBadge(current) }
                        }
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
            .gesture(TapGesture().onEnded { })
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: chromeReady)
            Spacer()
            bottomButton("list.bullet", label: "显示播放队列") {
                if panel == .lyrics {
                    queueVisible = true
                    panel = .artwork
                } else {
                    queueVisible.toggle()
                }
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
        (symbol.contains("quote") && panel == .lyrics) || (symbol.contains("list") && panel != .lyrics && queueVisible)
    }

    private var queuePanel: some View {
        let look = NowPlayingTransport.state(playing: player.playing, shuffle: player.shuffle, repeatMode: player.repeatMode)
        return VStack(alignment: .leading, spacing: 16) {
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
                LazyVStack(spacing: 0) {
                    ForEach(player.upcomingTracks) { track in
                        HStack(spacing: 8) {
                            Button { player.load(track) } label: {
                                SongRow(track: track, root: library.root, emphasis: .white)
                                    .equatable()
                            }
                            .buttonStyle(.plain)
                            .opacity(queueDrag?.id == track.id ? 0 : 1)
                            QueueDragHandle(lifted: queueDrag?.id == track.id) { state, location, translation in
                                updateQueueDrag(track, state: state, location: location, translation: translation)
                            }
                            .frame(width: 32, height: 44)
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            queueRowFrames[track.id] = frame
                        }
                        .onDisappear { queueRowFrames.removeValue(forKey: track.id) }
                        .offset(y: queueRowOffset(track))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: queueDrag?.target)
                        .contextMenu {
                            Button("从队列移除", systemImage: "minus.circle", role: .destructive) {
                                if let index = player.upcomingTracks.firstIndex(where: { $0.id == track.id }) {
                                    player.removeUpcoming(at: IndexSet(integer: index))
                                }
                            }
                            Button("向前移动", systemImage: "arrow.up") { moveUpcoming(track, backwards: true) }
                            Button("向后移动", systemImage: "arrow.down") { moveUpcoming(track, backwards: false) }
                        }
                    }
                }
                .accessibilityIdentifier("upcoming-queue")
            }
        }
        .padding(.top, 4)
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                if let drag = queueDrag,
                   let track = player.upcomingTracks.first(where: { $0.id == drag.id }) {
                    HStack(spacing: 8) {
                        SongRow(track: track, root: library.root, emphasis: .white)
                            .equatable()
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 32, height: 44)
                    }
                    .frame(width: drag.frame.width, height: drag.frame.height)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    .position(x: drag.frame.midX - geometry.frame(in: .global).minX + drag.translation.width,
                              y: drag.frame.midY - geometry.frame(in: .global).minY + drag.translation.height)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func queueRowOffset(_ track: Track) -> CGFloat {
        guard let drag = queueDrag, let index = drag.ids.firstIndex(of: track.id) else { return 0 }
        return QueueDropMapping.offset(index: index, source: drag.source, target: drag.target,
                                       rowHeight: drag.frame.height)
    }

    private func updateQueueDrag(_ track: Track, state: UIGestureRecognizer.State,
                                 location: CGPoint, translation: CGSize) {
        if state == .began {
            let ids = player.upcomingTracks.map(\.id)
            guard queueVisible,
                  let source = ids.firstIndex(of: track.id), queueRowFrames[track.id] != nil else { return }
            queueDrag = QueueRowDrag(ids: ids, source: source, frames: queueRowFrames,
                                     target: source, translation: translation)
        }
        guard var drag = queueDrag, drag.id == track.id else { return }
        guard state == .began || state == .changed || state == .ended else {
            queueDrag = nil
            return
        }
        // Freeze the original geometry for the session: neighbors' visual
        // offsets must never feed back into hover targeting.
        let candidates = drag.ids.indices.filter { drag.frames[drag.ids[$0]] != nil }
        let hovered = candidates.first { index in
            guard let frame = drag.frames[drag.ids[index]] else { return false }
            return location.y >= frame.minY && location.y < frame.maxY
        }
        if let target = hovered ?? candidates.min(by: {
            abs((drag.frames[drag.ids[$0]]?.midY ?? 0) - location.y) <
            abs((drag.frames[drag.ids[$1]]?.midY ?? 0) - location.y)
        }) { drag.target = target }
        drag.translation = translation
        if state == .ended {
            queueDrag = nil
            let bounds = candidates.reduce(CGRect.null) { $0.union(drag.frames[drag.ids[$1]] ?? .null) }
            guard bounds.contains(location), drag.ids == player.upcomingTracks.map(\.id),
                  let destination = QueueDropMapping.destination(source: drag.source, target: drag.target,
                                                               count: drag.ids.count) else { return }
            player.moveUpcoming(from: IndexSet(integer: drag.source), to: destination)
        } else {
            queueDrag = drag
        }
    }

    private func moveUpcoming(_ track: Track, backwards: Bool) {
        guard let index = player.upcomingTracks.firstIndex(where: { $0.id == track.id }) else { return }
        let destination = backwards ? max(0, index - 1) : min(player.upcomingTracks.count, index + 2)
        player.moveUpcoming(from: IndexSet(integer: index), to: destination)
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
}

/// Playback supplies its artwork; collection pages supply their own cover URL.
struct NowPlayingBackground: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore

    var body: some View {
        ArtworkBackground(url: library.track(player.current?.id)?.artworkFilename.map {
            library.root.appendingPathComponent($0)
        })
    }
}

/// One palette/texture loader for playback and collection covers. Key both the
/// cache and displayed result by URL so another collection cannot show stale art.
struct ArtworkBackground: View {
    var url: URL?
    var followsAppearance = false
    @State private var analysis: ArtworkAnalysis?
    @State private var resolvedURL: URL?

    private var displayed: ArtworkAnalysis? {
        if resolvedURL == url { return analysis }
        return url.flatMap { ArtworkAnalysisCache.shared.analysis(for: $0.absoluteString) }
    }

    var body: some View {
        ArtworkBackgroundSurface(analysis: displayed,
                                 imageKey: url?.absoluteString, followsAppearance: followsAppearance)
            .task(id: url) {
                analysis = nil
                resolvedURL = nil
                guard let requested = url else { return }
                let key = requested.absoluteString
                if let cached = ArtworkAnalysisCache.shared.analysis(for: key) {
                    analysis = cached
                    resolvedURL = requested
                    return
                }
                let loaded = await Task.detached(priority: .userInitiated) { () -> ArtworkAnalysis? in
                    guard let image = ArtworkCache.shared.image(at: requested, maxPixel: 160) else { return nil }
                    let ready = ArtworkAnalysis.make(from: image)
                    ArtworkAnalysisCache.shared.store(ready, for: key)
                    return ready
                }.value
                guard !Task.isCancelled, url == requested else { return }
                analysis = loaded
                resolvedURL = requested
            }
    }
}

/// Shared opaque full-size surface. Details inherit the window appearance and
/// add a legibility veil; playback retains its existing dark presentation.
struct ArtworkBackgroundSurface: View {
    var analysis: ArtworkAnalysis?
    var imageKey: String? = nil
    var followsAppearance = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            Color(white: 0.08)
                .overlay {
                    ArtworkBackdrop(colors: analysis?.palette.map { Color(uiColor: $0) } ?? [],
                                    image: analysis?.backdrop, imageKey: imageKey,
                                    extendsIntoSafeArea: false)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.5),
                                   value: analysis?.palette.map { Color(uiColor: $0) } ?? [])
                }
                .overlay {
                    if followsAppearance {
                        if scheme == .light { Color.white.opacity(0.82) }
                        else { Color.black.opacity(0.72) }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

struct ArtworkBackdrop: View {
    var colors: [Color]
    var image: UIImage? = nil
    var imageKey: String? = nil
    var extendsIntoSafeArea = true
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
        .ignoresSafeArea(edges: extendsIntoSafeArea ? .all : [])
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
