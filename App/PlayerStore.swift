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
final class PlayerStore: NSObject, ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var playing = false
    /// Drives the now-playing slider only. Library screens do not observe this clock.
    let clock = PlaybackClock()
    var position: Double {
        get { clock.position }
        set { clock.set(newValue) }
    }
    @Published private(set) var output = ""
    /// End-to-end judgement of the current playback chain, refreshed
    /// whenever the track, route or actual session rate may have changed.
    @Published private(set) var pathAssessment: AudioPathAssessment?
    @Published private(set) var shuffle = false
    @Published var repeatMode: RepeatMode = .all {
        didSet {
            if playbackReady, oldValue != repeatMode {
                invalidatePreload(.repeatChange)
                library.rememberTransport(shuffle: shuffle, repeatMode: repeatMode)
            }
        }
    }
    @Published private(set) var queueIDs: [UUID] = []
    private var accessRoot: URL?
    private var nextAccessRoot: URL?
    private var interruptedWhilePlaying = false
    private var ordering = QueueOrdering()
    private var playbackReady = false
    var queuedTracks: [Track] { library.tracks(for: queueIDs).filter(\.available) }
    /// The list the user started, in its pre-shuffle order.
    var contextIDs: [UUID] { ordering.context }
    @Published var errorMessage: String?
    private let library: LibraryStore
    private let engine = EnginePlayer()
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
        engine.onFinish = { [weak self] in
            guard let self else { return }
            if self.repeatMode == .one { self.seek(0); self.resume() } else { self.skip() }
        }
        engine.onAdvance = { [weak self] id in
            self?.advancePreloadedTrack(id)
        }
        configureRemote()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self?.interruptedWhilePlaying = self?.playing == true
                    self?.engine.pause()
                    self?.invalidatePreload(.interruption)
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
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.engine.pause() }
                self?.invalidatePreload(.routeChange)
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
                self?.updateOutput()
            }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        playbackReady = true
        if let track = library.track(saved.currentID), track.available {
            load(track, autoplay: false, at: saved.position, keepTransport: true)
        }
        updateOutput()
    }

    deinit {
        accessRoot?.stopAccessingSecurityScopedResource()
        nextAccessRoot?.stopAccessingSecurityScopedResource()
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        remoteTargets.forEach { $0.0.removeTarget($0.1) }
    }

    func load(_ track: Track, autoplay: Bool = true, at time: Double = 0, context: [Track]? = nil, keepTransport: Bool = false) {
        guard track.available else { errorMessage = "文件已移动或删除，请重新扫描文件夹"; return }
        invalidatePreload(.trackChange)
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
            // Ask the session for this track's own sample rate before the
            // engine connects, so the mixer does not have to resample a
            // 44.1 kHz file to 48 kHz (or a 96 kHz file down) by default.
            // The request is only a preference; `updateOutput` re-reads the
            // actual rate afterwards and the path assessment judges that.
            if autoplay { try prepareSession(for: track, activate: true) }
            else { prepareSessionPassively(for: track) }
            try engine.load(url: library.url(for: track), at: time)
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
            engine.enablePreloadForLoadedTrack()
            current = track
            position = min(max(0, time), engine.duration)
            library.remember(id: track.id, position: position)
            updateOutput()
            updateNowPlaying()
            if autoplay {
                resume()
                if playing { library.recordPlay(id: track.id) }
            }
        } catch { errorMessage = "播放失败：\(error.localizedDescription)" }
    }

    func toggle() {
        if playing { pause() }
        else if engine.hasFile { resume() }
        else if let first = library.tracks.firstPlayable() { load(first) }
    }

    /// Plays `tracks` in list order, or shuffled. Shuffle on remembers the list order so it can be restored.
    func play(_ tracks: [Track], shuffled: Bool) {
        invalidatePreload(.trackChange)
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
        guard engine.hasFile else { return }
        do {
            if let current { try prepareSession(for: current, activate: true) }
            playing = try engine.play()
            if !playing { errorMessage = "音频设备无法开始播放" }
            updateOutput()
            updateNowPlaying()
            if playing { preloadNextTrack() }
        } catch { errorMessage = "音频会话启动失败：\(error.localizedDescription)" }
    }

    /// Points the session at the track's sample rate. With `activate` the
    /// session is (re)activated so the preference can take effect; the
    /// passive variant only records the preference, so restoring a paused
    /// track at launch does not interrupt other apps' audio.
    private func prepareSession(for track: Track, activate: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        if track.sampleRate > 0 { try session.setPreferredSampleRate(track.sampleRate) }
        if activate { try session.setActive(true) }
    }

    private func prepareSessionPassively(for track: Track) {
        try? prepareSession(for: track, activate: false)
    }

    func pause() {
        position = engine.hasFile ? engine.currentTime : position
        engine.pause()
        invalidatePreload(.pause)
        playing = false
        if let current { library.remember(id: current.id, position: position) }
        updateNowPlaying()
    }

    func stopIfCurrent(_ track: Track) {
        guard current?.id == track.id else { return }
        invalidatePreload(.trackChange)
        engine.stop()
        playing = false
        accessRoot?.stopAccessingSecurityScopedResource(); accessRoot = nil
        current = nil
        position = 0
        pathAssessment = nil
        library.remember(id: nil, position: 0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(_ time: Double) {
        guard engine.hasFile, time.isFinite else { return }
        invalidatePreload(.seek)
        position = min(max(0, time), engine.duration)
        engine.seek(to: position)
        library.remember(id: current?.id, position: position)
        updateNowPlaying()
    }

    func setQueue(_ ids: [UUID], replacingContext: Bool = true) {
        var seen = Set<UUID>()
        let filtered = ids.filter { id in
            seen.insert(id).inserted && library.track(id)?.available == true
        }
        // recordPlay updates library metadata and triggers reconciliation too.
        // An unchanged queue must not cancel the segment we just appended.
        if filtered != queueIDs { invalidatePreload(.queueChange) }
        ordering.queue = filtered
        if replacingContext { ordering.context = filtered }
        else { ordering.context.removeAll { !seen.contains($0) } }
        queueIDs = ordering.queue
        library.rememberQueue(queueIDs, contextOrder: ordering.context, shuffle: shuffle)
    }

    func cycleRepeat() { repeatMode = repeatMode.cycled }

    func toggleShuffle() {
        invalidatePreload(.queueChange)
        ordering.queue = queueIDs
        ordering.shuffle = shuffle
        ordering.toggleShuffle(current: current?.id)
        shuffle = ordering.shuffle
        queueIDs = ordering.queue
        library.rememberQueue(queueIDs, contextOrder: ordering.context, shuffle: shuffle)
    }

    func enqueue(_ track: Track, next: Bool) {
        enqueue([track], next: next)
    }

    /// Play Next inserts after the current track. Add to Queue appends.
    /// With nothing loaded, Play Next starts in list order and Add to Queue pauses on the first track.
    /// Both of those idle cases turn shuffle off so the new queue order is the order the user asked for.
    func enqueue(_ tracks: [Track], next: Bool) {
        var seen = Set<UUID>()
        let chosen = tracks.filter { track in
            guard track.available, seen.insert(track.id).inserted else { return false }
            if let current, track.id == current.id { return false }
            return true
        }
        guard !chosen.isEmpty else { return }
        invalidatePreload(.queueChange)
        if current == nil {
            if next {
                play(chosen, shuffled: false)
            } else {
                let ids = chosen.map(\.id)
                ordering.applyPlay(orderedIDs: ids, queue: ids, shuffle: false)
                shuffle = ordering.shuffle
                queueIDs = ordering.queue
                library.rememberQueue(queueIDs, contextOrder: ordering.context, shuffle: shuffle)
                if let first = chosen.first { load(first, autoplay: false, keepTransport: true) }
            }
            return
        }
        ordering.queue = queueIDs
        ordering.shuffle = shuffle
        ordering.insert(chosen.map(\.id), after: current?.id, next: next)
        queueIDs = ordering.queue
        library.rememberQueue(queueIDs, contextOrder: ordering.context, shuffle: shuffle)
    }

    var upcomingTracks: [Track] {
        let tracks = queuedTracks
        guard let id = current?.id, let index = tracks.firstIndex(where: { $0.id == id }) else { return tracks }
        return Array(tracks.dropFirst(index + 1))
    }

    func removeUpcoming(at offsets: IndexSet) {
        let start = queuedTracks.count - upcomingTracks.count
        removeQueue(at: IndexSet(offsets.map { $0 + start }))
    }

    func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        let start = queuedTracks.count - upcomingTracks.count
        moveQueue(from: IndexSet(offsets.map { $0 + start }), to: destination + start)
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
            if let track = library.track(old.id) {
                current = track
                if !track.available { pause() }
            } else { stopIfCurrent(old) }
        }
    }

    func skip(backwards: Bool = false) {
        if backwards && position > 3 { seek(0); return }
        let id = PlaybackQueue(ids: queuedTracks.map(\.id), repeatAll: repeatMode != .off)
            .next(after: current?.id, backwards: backwards)
        if let track = library.track(id), track.available { load(track) }
        else { pause(); seek(0) }
    }

    private func invalidatePreload(_ reason: GaplessQueueState.Invalidation) {
        engine.invalidatePreload(reason)
        nextAccessRoot?.stopAccessingSecurityScopedResource()
        nextAccessRoot = nil
    }

    /// Resolve scoped files before appending, and keep the next scope alive
    /// until it is either cancelled or becomes the current track's scope.
    private func preloadNextTrack() {
        guard let current else { return }
        let id = GaplessQueueState.nextTrack(in: queuedTracks.map(\.id), after: current.id,
                                            repeatMode: repeatMode)
        guard let track = library.track(id), track.available else { return }
        do {
            var root: URL?
            if let folderID = track.folderID {
                guard let folder = library.snapshot.folders.first(where: { $0.id == folderID }) else { return }
                root = try library.resolve(folder)
            }
            let scoped = root?.startAccessingSecurityScopedResource() == true
            var accepted = false
            defer { if scoped && !accepted { root?.stopAccessingSecurityScopedResource() } }
            if try engine.preload(url: library.url(for: track), id: track.id) {
                nextAccessRoot = scoped ? root : nil
                accepted = true
            }
        } catch {
            // Opening/format failures use the existing load path at the boundary.
        }
    }

    private func advancePreloadedTrack(_ id: UUID) {
        guard let track = library.track(id), track.available else {
            invalidatePreload(.trackChange)
            skip()
            return
        }
        accessRoot?.stopAccessingSecurityScopedResource()
        accessRoot = nextAccessRoot
        nextAccessRoot = nil
        current = track
        position = engine.currentTime
        library.remember(id: id, position: position)
        library.recordPlay(id: id)
        updateOutput()
        updateNowPlaying()
        preloadNextTrack()
    }

    private func tick() {
        guard playing else { return }
        position = engine.currentTime
        ticks += 1
        // Every 5 seconds. The checkpoint writes off the main thread, and
        // updateOutput assigns only when the route string or the path
        // judgement actually changes — assigning @Published unconditionally
        // invalidated every library list while a song was playing.
        if ticks % 10 == 0 {
            library.checkpointPlayback(id: current?.id, position: position)
            updateOutput()
        }
    }

    private func updateOutput() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let names = outputs.map(\.portName).joined(separator: ", ")
        let nextOutput = "\(names.isEmpty ? "系统输出" : names) · \(String(format: "%.1f", session.sampleRate / 1000)) kHz"
        if output != nextOutput { output = nextOutput }
        // The engine's digital volume is pinned at 1.0 (see EnginePlayer);
        // the system volume shown in the player is the output device gain,
        // not a scaling of the samples inside the engine.
        guard let current else { return }
        let assessment = AudioPathAssessment.assess(
            isLosslessSource: current.isLosslessSource,
            sourceSampleRate: current.sampleRate,
            sessionSampleRate: session.sampleRate,
            route: outputs.first.map { AudioRouteKind.from($0.portType) } ?? .other,
            digitalVolume: 1.0)
        if pathAssessment != assessment { pathAssessment = assessment }
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
        let trackID = current.id
        if let name = current.artworkFilename {
            let url = library.root.appendingPathComponent(name)
            if let image = ArtworkCache.shared.cachedImage(at: url, maxPixel: 700) {
                info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(image)
            } else {
                if let preview = ArtworkCache.shared.bestCachedImage(at: url, maxPixel: 700) {
                    info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(preview)
                }
                Task { @MainActor in
                    let image = await ArtworkCache.shared.load(at: url, maxPixel: 700)
                    guard self.current?.id == trackID, let image else { return }
                    var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    updated[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(image)
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
                }
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private static func nowPlayingArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
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
}
