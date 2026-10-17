import AVFoundation
import MediaPlayer
import Combine

@MainActor
final class PlayerStore: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var current: Track?
    @Published private(set) var playing = false
    @Published private(set) var position: Double = 0
    @Published private(set) var output = ""
    @Published var shuffle = false
    @Published var repeatAll = true
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
        configureRemote()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                if type == AVAudioSession.InterruptionType.began.rawValue { self?.pause() }
                else if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { self?.resume() }
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
        if let track = library.tracks.first(where: { $0.id == library.snapshot.currentID }) {
            load(track, autoplay: false, at: library.snapshot.position)
        }
        updateOutput()
    }

    deinit {
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        remoteTargets.forEach { $0.0.removeTarget($0.1) }
    }

    func load(_ track: Track, autoplay: Bool = true, at time: Double = 0) {
        pause()
        do {
            let next = try AVAudioPlayer(contentsOf: library.url(for: track))
            next.delegate = self
            next.prepareToPlay()
            player = next
            current = track
            position = min(max(0, time), next.duration)
            next.currentTime = position
            library.remember(id: track.id, position: position)
            updateNowPlaying()
            if autoplay { resume() }
        } catch { errorMessage = "播放失败：\(error.localizedDescription)" }
    }

    func toggle() {
        if playing { pause() }
        else if player != nil { resume() }
        else if let first = library.tracks.first { load(first) }
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
        current = nil
        position = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(_ time: Double) {
        guard let player, time.isFinite else { return }
        position = min(max(0, time), player.duration)
        player.currentTime = position
        library.remember(id: current?.id, position: position)
        updateNowPlaying()
    }

    func skip(backwards: Bool = false) {
        if backwards && position > 3 { seek(0); return }
        let ids = library.tracks.map(\.id)
        let nextID: UUID?
        if shuffle && !backwards {
            nextID = ids.filter { $0 != current?.id }.randomElement() ?? ids.first
        } else {
            nextID = PlaybackQueue(ids: ids, repeatAll: repeatAll).next(after: current?.id, backwards: backwards)
        }
        if let track = library.tracks.first(where: { $0.id == nextID }) { load(track) }
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyAlbumTitle: current.album,
            MPMediaItemPropertyPlaybackDuration: current.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
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
            if flag { self.skip() }
            else { self.pause(); self.errorMessage = "音频播放意外结束" }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? "无法解码音频"
        Task { @MainActor [weak self] in self?.pause(); self?.errorMessage = message }
    }
}
