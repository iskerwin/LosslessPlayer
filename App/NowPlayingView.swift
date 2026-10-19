import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer
import CoreImage

struct NowPlayingView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    @ObservedObject private var playbackClock: PlaybackClock
    var onOpen: (LibraryRoute) -> Void
    var onDelete: (Track) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(library: LibraryStore, player: PlayerStore, onOpen: @escaping (LibraryRoute) -> Void = { _ in }, onDelete: @escaping (Track) -> Void = { _ in }) {
        self.library = library
        self.player = player
        self.onOpen = onOpen
        self.onDelete = onDelete
        _playbackClock = ObservedObject(wrappedValue: player.clock)
    }

    private enum Panel { case artwork, lyrics, queue }
    @State private var panel = Panel.artwork
    @State private var scrubbing = false
    @State private var draft: Double = 0
    @State private var details = false
    @State private var playlistTarget: Track?
    @GestureState private var dismissOffset: CGFloat = 0
    @State private var palette: [Color] = ArtworkColors.fallback.map { Color($0) }
    private var current: Track? { library.tracks.first { $0.id == player.current?.id } }
    private var duration: Double {
        let duration = current?.duration ?? 0
        return duration.isFinite && duration > 0 ? duration : 0
    }

    var body: some View {
        ZStack {
            ArtworkBackdrop(colors: palette)
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
        .offset(y: reduceMotion ? 0 : dismissOffset)
        .background(Color(white: 0.08).ignoresSafeArea())
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: dismissOffset)
        .foregroundStyle(.white)
        .tint(.white)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-playing")
        .onAppear(perform: refreshPalette)
        .onChange(of: current?.artworkFilename) { _, _ in refreshPalette() }
        .onChange(of: current?.id) { _, _ in scrubbing = false }
        .accessibilityAction(.escape) { dismiss() }
        .sheet(item: $playlistTarget) { track in
            AddToPlaylistSheet(library: library, tracks: [track])
        }
        .sheet(isPresented: $details) { detailsSheet }
    }

    private func playerContent(stageHeight: CGFloat?) -> some View {
        VStack(spacing: 0) {
            Button { dismiss() } label: {
                Capsule()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 60, height: 4)
                    .frame(width: 90, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起播放器")
            .simultaneousGesture(dismissGesture)
            stage
                .frame(height: stageHeight)
                .frame(minHeight: 120, maxHeight: stageHeight == nil ? .infinity : nil)
                .padding(.bottom, 24)
            VStack(spacing: 8) {
                titleBlock
                scrubber
                transport
                    .padding(.top, 18)
            }
            .fixedSize(horizontal: false, vertical: true)
            SystemVolumeBar()
                .padding(.top, 32)
            bottomRow
                .padding(.top, 18)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 12)
        .frame(maxWidth: 560, maxHeight: stageHeight == nil ? .infinity : nil)
        .frame(maxWidth: .infinity)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .updating($dismissOffset) { value, offset, _ in
                if value.translation.height > abs(value.translation.width) * 1.5 {
                    offset = max(0, value.translation.height)
                }
            }
            .onEnded { value in
                if value.translation.height > 90,
                   value.translation.height > abs(value.translation.width) * 1.5 {
                    dismiss()
                }
            }
    }

    @ViewBuilder private var stage: some View {
        ZStack {
            if panel == .artwork {
                GeometryReader { geometry in
                    let side = max(0, min(geometry.size.width * 0.90, geometry.size.height * 0.9))
                    ArtworkView(track: current, root: library.root, size: side, placeholder: .neutral)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
                        .scaleEffect(player.playing ? 1 : 0.86)
                        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82), value: player.playing)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(dismissGesture)
            } else if panel == .lyrics {
                lyricsPanel
            } else {
                queuePanel
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: panel)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current?.title ?? "未在播放")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .multilineTextAlignment(.leading)
                    if let current {
                        Button {
                            onOpen(.artist(current.artist))
                            dismiss()
                        } label: {
                            Text(current.artist)
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("选择一首歌曲").font(.title3).foregroundStyle(.white.opacity(0.6))
                    }
                }
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
                            dismiss()
                        }
                        Button("前往艺术家", systemImage: "music.mic") {
                            onOpen(.artist(current.artist))
                            dismiss()
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
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            ThinScrubber(value: Binding(
                get: { scrubbing ? draft : min(playbackClock.position, duration) },
                set: { draft = $0 }
            ), range: 0...(duration > 0 ? duration : 1), onEditingChanged: { editing in
                if editing {
                    draft = playbackClock.position
                    scrubbing = true
                } else {
                    if scrubbing, duration > 0 { player.seek(draft) }
                    scrubbing = false
                }
            }, onCancel: { scrubbing = false })
            .id(current?.id)
            .disabled(duration == 0)
            .accessibilityLabel("播放进度")
            .accessibilityValue(duration > 0 ? "\(clock(scrubbing ? draft : playbackClock.position))，共 \(clock(duration))" : "时长未知")
            .accessibilityIdentifier("playback-progress")
            HStack {
                Text(duration > 0 ? clock(scrubbing ? draft : playbackClock.position) : "--:--")
                Spacer()
                Text(duration > 0 ? "−" + clock(max(0, duration - (scrubbing ? draft : playbackClock.position))) : "--:--")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var transport: some View {
        let symbol = player.playing ? "pause.fill" : "play.fill"
        return HStack {
            transportButton("backward.fill", label: "上一首", size: 34) { player.skip(backwards: true) }
            Spacer()
            transportButton(symbol, label: player.playing ? "暂停" : "播放", size: 44) { player.toggle() }
            Spacer()
            transportButton("forward.fill", label: "下一首", size: 34) { player.skip() }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }

    private func transportButton(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
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
            RoutePicker()
                .frame(width: 48, height: 44)
                .accessibilityLabel("选择音频输出")
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
                        RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.16))
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("接下来").font(.headline)
                Spacer()
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(look.shuffleHighlighted ? 1 : 0.4))
                .accessibilityLabel("切换随机播放")
                .accessibilityValue(look.shuffleHighlighted ? "已开启" : "已关闭")
                Button { player.cycleRepeat() } label: {
                    Image(systemName: look.repeatSymbol).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(look.repeatHighlighted ? 1 : 0.4))
                .accessibilityLabel(look.repeatAccessibility)
            }
            List {
                ForEach(player.queuedTracks) { track in
                    SongContextRow(
                        track: track,
                        root: library.root,
                        current: track.id == current?.id,
                        playing: player.playing && track.id == current?.id,
                        emphasis: .white,
                        handlers: handlers
                    )
                }
                .onDelete { player.removeQueue(at: $0) }
                .onMove { player.moveQueue(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var lyricsPanel: some View {
        if let text = current?.lyrics, current?.hasLyrics == true {
            LyricsScroll(lines: LyricsLine.parse(text), position: playbackClock.position) { player.seek($0) }
        } else {
            ContentUnavailableView("暂无本地歌词", systemImage: "quote.bubble", description: Text("将同名 UTF-8 .lrc 文件放在音乐旁，重新扫描后显示。"))
        }
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
                    LabeledContent("文件", value: current.relativePath ?? current.filename)
                    Text("高音质本地播放，声音经过 iOS 系统混音。文件格式和输出采样率都不表示逐位还原。")
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
            album: { onOpen(.album($0.albumID)); dismiss() },
            artist: { onOpen(.artist($0.artist)); dismiss() },
            lyrics: { _ in panel = .lyrics },
            delete: onDelete
        )
    }

    private func refreshPalette() {
        let image = current?.artworkFilename.flatMap { ArtworkCache.shared.image(at: library.root.appendingPathComponent($0)) }
        palette = ArtworkColors.palette(from: image).map { Color(uiColor: $0) }
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
            let thickness: CGFloat = dragging ? 7 : 4
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
        .frame(height: 44)
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

    private static func average(_ image: CIImage, rect: CGRect) -> UIColor? {
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
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

struct ArtworkBackdrop: View {
    var colors: [Color]
    @State private var drift = false

    var body: some View {
        Group {
            if #available(iOS 18, *) {
                MeshGradient(width: 3, height: 3, points: points, colors: meshColors)
            } else {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .overlay {
            LinearGradient(colors: [.white.opacity(0.06), .clear, .black.opacity(0.32)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .onAppear { drift = true }
    }

    private var meshColors: [Color] {
        let base = colors.isEmpty ? ArtworkColors.fallback.map { Color(uiColor: $0) } : colors
        return (0..<9).map { base[$0 % base.count] }
    }

    private var points: [SIMD2<Float>] {
        let nudge: Float = drift ? 0.08 : -0.04
        return [
            SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0),
            SIMD2(0, 0.5 + nudge), SIMD2(0.5 + nudge, 0.48), SIMD2(1, 0.5 - nudge),
            SIMD2(0, 1), SIMD2(0.5, 1), SIMD2(1, 1)
        ]
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
                        Button { if let time = line.time { seek(time) } } label: {
                            Text(line.text).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(line.time == nil || index == active ? Color.white : Color.white.opacity(0.45))
                        }
                        .buttonStyle(.plain)
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

struct LyricsReader: View {
    @ObservedObject var player: PlayerStore
    @ObservedObject private var clock: PlaybackClock
    let track: Track
    @Environment(\.dismiss) private var dismiss

    init(player: PlayerStore, track: Track) {
        self.player = player
        self.track = track
        _clock = ObservedObject(wrappedValue: player.clock)
    }

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        NavigationStack {
            Group {
                if track.hasLyrics, let text = track.lyrics {
                    LyricsScroll(lines: LyricsLine.parse(text), position: isCurrent ? clock.position : nil) { time in
                        if isCurrent || player.queueIDs.contains(track.id) {
                            if isCurrent { player.seek(time) }
                            else { player.load(track, at: time, keepTransport: true) }
                        } else {
                            player.load(track, at: time)
                        }
                    }
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

struct SystemVolumeBar: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.footnote)
                .accessibilityHidden(true)
            NativeVolumeView()
                .frame(height: 44)
            Image(systemName: "speaker.wave.3.fill")
                .font(.footnote)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.white.opacity(0.6))
    }
}

/// Let the system own volume changes, accessibility, hardware buttons, and fixed-volume routes.
private struct NativeVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.tintColor = UIColor.white.withAlphaComponent(0.65)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        view.tintColor = UIColor.white.withAlphaComponent(0.65)
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
