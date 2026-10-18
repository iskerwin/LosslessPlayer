import AVFoundation
import MediaPlayer
import Combine
import UIKit

@MainActor
final class PlayerStore: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var current: Track?
    @Published private(set) var playing = false
    @Published private(set) var position: Double = 0
    @Published private(set) var output = ""
    @Published private(set) var shuffle = false
    @Published var repeatMode: RepeatMode = .all
    @Published private(set) var queueIDs: [UUID] = []
    private var accessRoot: URL?
    private var interruptedWhilePlaying = false
    enum RepeatMode { case off, all, one }
    var queuedTracks: [Track] { queueIDs.compactMap { id in library.tracks.first { $0.id == id && $0.available } } }
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
        queueIDs = library.snapshot.queueIDs.filter { id in library.tracks.contains { $0.id == id && $0.available } }
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
        if let track = library.tracks.first(where: { $0.id == library.snapshot.currentID }) {
            load(track, autoplay: false, at: library.snapshot.position)
        }
        updateOutput()
    }

    deinit {
        accessRoot?.stopAccessingSecurityScopedResource()
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        remoteTargets.forEach { $0.0.removeTarget($0.1) }
    }

    func load(_ track: Track, autoplay: Bool = true, at time: Double = 0, context: [Track]? = nil) {
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
            if let context { setQueue(context.map(\.id)) }
            else if !queueIDs.contains(track.id) { setQueue(library.tracks.filter(\.available).map(\.id)) }
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
        accessRoot?.stopAccessingSecurityScopedResource(); accessRoot = nil
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

    func setQueue(_ ids: [UUID]) {
        queueIDs = ids.filter { id in library.tracks.contains { $0.id == id && $0.available } }
        library.rememberQueue(queueIDs)
    }

    func toggleShuffle() {
        shuffle.toggle()
        guard let id = current?.id else { return }
        var rest = queueIDs.filter { $0 != id }
        if shuffle { rest.shuffle() }
        else { rest = library.tracks.filter { rest.contains($0.id) }.map(\.id) }
        setQueue([id] + rest)
    }

    func enqueue(_ track: Track, next: Bool) {
        guard track.available, track.id != current?.id else { return }
        var ids = queueIDs.filter { $0 != track.id }
        if next, let id = current?.id, let index = ids.firstIndex(of: id) { ids.insert(track.id, at: index + 1) }
        else { ids.append(track.id) }
        setQueue(ids)
    }

    func removeQueue(at offsets: IndexSet) {
        var ids = queueIDs
        for i in offsets.sorted(by: >) where ids.indices.contains(i) { ids.remove(at: i) }
        setQueue(ids)
    }

    func moveQueue(from offsets: IndexSet, to destination: Int) {
        var ids = queueIDs
        let moving = offsets.sorted().map { ids[$0] }
        for i in offsets.sorted(by: >) { ids.remove(at: i) }
        ids.insert(contentsOf: moving, at: destination - offsets.filter { $0 < destination }.count)
        setQueue(ids)
    }

    func reconcileLibrary() {
        setQueue(queueIDs)
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
