import AVFoundation
import MediaPlayer
import Combine
import UIKit

@MainActor
final class PlaybackClock: ObservableObject {
    @Published private(set) var position: Double = 0
    func set(_ value: Double) {
        let next = value.isFinite ? max(0, value) : 0
        if next != position { position = next }
    }
}

@MainActor
final class PlayerStore: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var current: Track?
    @Published private(set) var playing = false
    /// Drives the now-playing slider only. Library screens do not observe this clock.
    let clock = PlaybackClock()
    var position: Double {
        get { clock.position }
        set { clock.set(newValue) }
    }
    @Published private(set) var output = ""
    @Published private(set) var shuffle = false
    @Published var repeatMode: RepeatMode = .all {
        didSet { if playbackReady, oldValue != repeatMode { library.rememberTransport(shuffle: shuffle, repeatMode: repeatMode) } }
    }
    @Published private(set) var queueIDs: [UUID] = []
    private var accessRoot: URL?
    private var interruptedWhilePlaying = false
    private var ordering = QueueOrdering()
    private var playbackReady = false
    var queuedTracks: [Track] { queueIDs.compactMap { id in library.tracks.first { $0.id == id && $0.available } } }
    /// The list the user started, in its pre-shuffle order.
    var contextIDs: [UUID] { ordering.context }
    @Published var errorMessage: String?
    private let library: LibraryStore
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var ticks = 0

    init(library: LibraryStore) {
        self.library = library
        super.init()
        let saved = library.playback
        let available: (UUID) -> Bool = { id in library.tracks.contains { $0.id == id && $0.available } }
        ordering.queue = saved.queueIDs.filter(available)
        ordering.context = saved.contextOrder.filter(available)
        if ordering.context.isEmpty { ordering.context = ordering.queue }
        ordering.shuffle = saved.shuffle
        queueIDs = ordering.queue
        shuffle = saved.shuffle
        repeatMode = saved.repeatMode
        configureRemote()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self?.interruptedWhilePlaying = self?.playing == true
                    self?.pause()
                } else if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume),
                          self?.interruptedWhilePlaying == true {
                    self?.interruptedWhilePlaying = false; self?.resume()
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
                self?.updateOutput()
            }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        playbackReady = true
        if let track = library.tracks.first(where: { $0.id == saved.currentID && $0.available }) {
            load(track, autoplay: false, at: saved.position, keepTransport: true)
        }
        updateOutput()
    }

    deinit {
        accessRoot?.stopAccessingSecurityScopedResource()
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        remoteTargets.forEach { $0.0.removeTarget($0.1) }
    }

    func load(_ track: Track, autoplay: Bool = true, at time: Double = 0, context: [Track]? = nil, keepTransport: Bool = false) {
        guard track.available else { errorMessage = "文件已移动或删除，请重新扫描文件夹"; return }
        pause()
        do {
            let newAccess: URL?
            if let id = track.folderID {
                guard let folder = library.snapshot.folders.first(where: { $0.id == id }) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                newAccess = try library.resolve(folder)
            } else { newAccess = nil }
            let scoped = newAccess?.startAccessingSecurityScopedResource() == true
            var accepted = false
            defer { if scoped && !accepted { newAccess?.stopAccessingSecurityScopedResource() } }
            let next = try AVAudioPlayer(contentsOf: library.url(for: track))
            accessRoot?.stopAccessingSecurityScopedResource()
            accessRoot = scoped ? newAccess : nil
            accepted = true
            if !keepTransport {
                if let context {
                    shuffle = false
                    setQueue(context.map(\.id), replacingContext: true)
                } else if !queueIDs.contains(track.id) {
                    shuffle = false
                    setQueue(library.tracks.filter(\.available).map(\.id), replacingContext: true)
                }
            }
            next.delegate = self
            next.prepareToPlay()
            player = next
            current = track
            position = min(max(0, time), next.duration)
            next.currentTime = position
            library.remember(id: track.id, position: position)
            updateNowPlaying()
            if autoplay {
                resume()
                if playing { library.recordPlay(id: track.id) }
            }
        } catch { errorMessage = "播放失败：\(error.localizedDescription)" }
    }

    func toggle() {
        if playing { pause() }
        else if player != nil { resume() }
        else if let first = library.tracks.firstPlayable() { load(first) }
    }

    /// Plays `tracks` in list order, or shuffled. Shuffle on remembers the list order so it can be restored.
    func play(_ tracks: [Track], shuffled: Bool) {
        let available = tracks.filter(\.available)
        guard !available.isEmpty else { return }
        let ordered = available.map(\.id)
        var queue = ordered
        if shuffled { queue.shuffle() }
        ordering.applyPlay(orderedIDs: ordered, queue: queue, shuffle: shuffled)
        shuffle = ordering.shuffle
        queueIDs = ordering.queue
        library.rememberQueue(queueIDs, contextOrder: ordering.context, shuffle: shuffle)
        guard let first = available.first(where: { $0.id == queue.first }) else { return }
        load(first, keepTransport: true)
    }

    func resume() {
        guard let player else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            playing = player.play()
            if !playing { errorMessage = "音频设备无法开始播放" }
            updateOutput()
            updateNowPlaying()
        } catch { errorMessage = "音频会话启动失败：\(error.localizedDescription)" }
    }

    func pause() {
        player?.pause()
        playing = false
        position = player?.currentTime ?? position
        if let current { library.remember(id: current.id, position: position) }
        updateNowPlaying()
    }

    func stopIfCurrent(_ track: Track) {
        guard current?.id == track.id else { return }
        pause()
        player = nil
        accessRoot?.stopAccessingSecurityScopedResource(); accessRoot = nil
        current = nil
        position = 0
        library.remember(id: nil, position: 0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(_ time: Double) {
        guard let player, time.isFinite else { return }
        position = min(max(0, time), player.duration)
        player.currentTime = position
        library.remember(id: current?.id, position: position)
        updateNowPlaying()
    }

    func setQueue(_ ids: [UUID], replacingContext: Bool = true) {
        var seen = Set<UUID>()
        let filtered = ids.filter { id in
            library.tracks.contains { $0.id == id && $0.available } && seen.insert(id).inserted
        }
        ordering.queue = filtered
        if replacingContext { ordering.context = filtered }
        else { ordering.context.removeAll { !seen.contains($0) } }
        queueIDs = ordering.queue
        library.rememberQueue(queueIDs, contextOrder: ordering.context, shuffle: shuffle)
    }

    func cycleRepeat() { repeatMode = repeatMode.cycled }

    func toggleShuffle() {
        ordering.queue = queueIDs
        ordering.shuffle = shuffle
        ordering.toggleShuffle(current: current?.id)
        shuffle = ordering.shuffle
        queueIDs = ordering.queue
        library.rememberQueue(queueIDs, contextOrder: ordering.context, shuffle: shuffle)
    }

    func enqueue(_ track: Track, next: Bool) {
        guard track.available, track.id != current?.id else { return }
        var ids = queueIDs.filter { $0 != track.id }
        ordering.context.removeAll { $0 == track.id }
        if next, let id = current?.id, let index = ids.firstIndex(of: id) {
            ids.insert(track.id, at: index + 1)
            if let contextIndex = ordering.context.firstIndex(of: id) { ordering.context.insert(track.id, at: contextIndex + 1) }
            else { ordering.context.append(track.id) }
        } else {
            ids.append(track.id)
            ordering.context.append(track.id)
        }
        setQueue(ids, replacingContext: false)
    }

    func removeQueue(at offsets: IndexSet) {
        var ids = queuedTracks.map(\.id)
        let removed = Set(offsets.compactMap { ids.indices.contains($0) ? ids[$0] : nil })
        for index in offsets.sorted(by: >) where ids.indices.contains(index) { ids.remove(at: index) }
        ordering.context.removeAll { removed.contains($0) }
        setQueue(ids, replacingContext: false)
    }

    func moveQueue(from offsets: IndexSet, to destination: Int) {
        var ids = queuedTracks.map(\.id)
        let moving = offsets.sorted().compactMap { ids.indices.contains($0) ? ids[$0] : nil }
        for index in offsets.sorted(by: >) where ids.indices.contains(index) { ids.remove(at: index) }
        let insertion = destination - offsets.filter { $0 < destination }.count
        let clamped = min(max(0, insertion), ids.count)
        ids.insert(contentsOf: moving, at: clamped)
        if !shuffle { ordering.context = ids }
        setQueue(ids, replacingContext: false)
    }

    func reconcileLibrary() {
        let live = Set(library.tracks.filter(\.available).map(\.id))
        ordering.context.removeAll { !live.contains($0) }
        setQueue(queueIDs.filter { live.contains($0) }, replacingContext: false)
        if let old = current {
            if let track = library.tracks.first(where: { $0.id == old.id }) {
                current = track
                if !track.available { pause() }
            } else { stopIfCurrent(old) }
        }
    }

    func skip(backwards: Bool = false) {
        if backwards && position > 3 { seek(0); return }
        let id = PlaybackQueue(ids: queuedTracks.map(\.id), repeatAll: repeatMode != .off)
            .next(after: current?.id, backwards: backwards)
        if let track = library.tracks.first(where: { $0.id == id && $0.available }) { load(track) }
        else { pause(); seek(0) }
    }

    private func tick() {
        guard playing else { return }
        position = player?.currentTime ?? 0
        ticks += 1
        if ticks % 10 == 0 { library.remember(id: current?.id, position: position) }
    }

    private func updateOutput() {
        let session = AVAudioSession.sharedInstance()
        let names = session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
        output = "\(names.isEmpty ? "系统输出" : names) · \(String(format: "%.1f", session.sampleRate / 1000)) kHz"
    }

    private func updateNowPlaying() {
        guard let current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyAlbumTitle: current.album,
            MPMediaItemPropertyPlaybackDuration: current.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
        if let name = current.artworkFilename,
           let image = UIImage(contentsOfFile: library.root.appendingPathComponent(name).path) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemote() {
        let center = MPRemoteCommandCenter.shared()
        func register(_ command: MPRemoteCommand, action: @escaping @MainActor () -> Void) {
            let target = command.addTarget { _ in
                Task { @MainActor in action() }
                return .success
            }
            remoteTargets.append((command, target))
        }
        register(center.playCommand) { [weak self] in self?.resume() }
        register(center.pauseCommand) { [weak self] in self?.pause() }
        register(center.togglePlayPauseCommand) { [weak self] in self?.toggle() }
        register(center.nextTrackCommand) { [weak self] in self?.skip() }
        register(center.previousTrackCommand) { [weak self] in self?.skip(backwards: true) }
        let target = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor [weak self] in self?.seek(time) }
            return .success
        }
        remoteTargets.append((center.changePlaybackPositionCommand, target))
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            if flag {
                if self.repeatMode == .one { self.seek(0); self.resume() } else { self.skip() }
            }
            else { self.pause(); self.errorMessage = "音频播放意外结束" }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? "无法解码音频"
        Task { @MainActor [weak self] in self?.pause(); self?.errorMessage = message }
    }
}
