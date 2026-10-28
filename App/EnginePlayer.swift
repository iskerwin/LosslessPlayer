import Foundation
import AVFoundation

/// Lossless playback engine: `AVAudioFile` streams into an `AVAudioPlayerNode`
/// connected straight to the engine's main mixer — no EQ, no effects, no
/// converter nodes in between — with both digital volumes pinned at 1.0 so
/// samples are not scaled on the way out.
///
/// The main mixer and the system output are still Apple's; whether the chain
/// stays bit-perfect depends on the session sample rate and the route, which
/// `AudioPathAssessment` judges from the live session. This type only
/// guarantees its own part: decode once, at the file's own format, with no
/// processing, streamed in segments instead of loading a whole file into RAM.
@MainActor
final class EnginePlayer {
    /// Called on the main actor when the scheduled file plays to its end.
    /// Stale scheduling tokens never reach this handler.
    var onFinish: (() -> Void)?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var segmentStartFrame: AVAudioFramePosition = 0
    var onAdvance: ((UUID) -> Void)?
    private var queue = GaplessQueueState()
    private var nextFile: AVAudioFile?
    // Node time is continuous across tracks, but each track's UI clock starts at zero.
    private var timelineStartFrame: AVAudioFramePosition = 0
    private var scheduledEndFrame: AVAudioFramePosition = 0

    private(set) var duration: Double = 0
    var hasFile: Bool { file != nil }
    var isPlaying: Bool { node.isPlaying }

    init() {
        engine.attach(node)
        node.volume = 1.0
        engine.mainMixerNode.outputVolume = 1.0
    }

    /// Opens `url` and schedules it from the start (or `time`), without
    /// starting playback. The previously loaded file is only dropped after
    /// the new one opens successfully, so a corrupt next track cannot
    /// destroy a paused one.
    func load(url: URL, at time: Double = 0) throws {
        let next = try AVAudioFile(forReading: url)
        guard next.length > 0, next.fileFormat.sampleRate > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        queue.invalidate(.trackChange)
        nextFile = nil
        node.stop()
        engine.stop()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: next.processingFormat)
        node.volume = 1.0
        engine.mainMixerNode.outputVolume = 1.0
        file = next
        duration = Double(next.length) / next.fileFormat.sampleRate
        schedule(from: frame(for: time), allowPreload: true)
        engine.prepare()
    }

    /// Starts or resumes playback. Returns whether the node is playing.
    @discardableResult
    func play() throws -> Bool {
        guard file != nil else { return false }
        if !engine.isRunning { try engine.start() }
        node.play()
        return node.isPlaying
    }

    func pause() {
        node.pause()
    }

    func stop() {
        queue.invalidate(.trackChange)
        nextFile = nil
        node.stop()
        engine.stop()
        file = nil
        duration = 0
        segmentStartFrame = 0
    }

    func seek(to time: Double) {
        guard file != nil else { return }
        let wasPlaying = node.isPlaying
        queue.invalidate(.seek)
        nextFile = nil
        schedule(from: frame(for: time), allowPreload: false)
        if wasPlaying {
            if !engine.isRunning { try? engine.start() }
            node.play()
        }
    }

    /// Playback position in seconds. `playerTime` counts samples rendered
    /// since the node was last stopped. Subtract the track's timeline offset
    /// after a seamless transition; seeks add the segment's starting frame.
    var currentTime: Double {
        guard let file else { return 0 }
        let rate = file.fileFormat.sampleRate
        guard rate > 0 else { return 0 }
        let base = Double(segmentStartFrame) / rate
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return base }
        let played = Double(playerTime.sampleTime) / playerTime.sampleRate
        return min(max(0, base + played - Double(timelineStartFrame) / rate), duration)
    }

    private func frame(for time: Double) -> AVAudioFramePosition {
        guard let file, time.isFinite, time > 0 else { return 0 }
        let frame = AVAudioFramePosition(time * file.fileFormat.sampleRate)
        return min(frame, max(0, file.length - 1))
    }

    /// Append on this node without touching the engine, session or current segment.
    @discardableResult
    func preload(url: URL, id: UUID) throws -> Bool {
        guard queue.allowsPreload, queue.pending == nil, let file else { return false }
        let next = try AVAudioFile(forReading: url)
        guard next.length > 0, next.length <= Int64(UInt32.max),
              GaplessCompatibility.canJoin(file.processingFormat, next.processingFormat),
              let token = queue.enqueue(id) else { return false }
        nextFile = next
        append(next, from: 0, token: token)
        return true
    }

    /// AVAudioPlayerNode cannot remove just its tail. Rebuild only the current
    /// segment at the current position, and reject callbacks from the old tail.
    func invalidatePreload(_ reason: GaplessQueueState.Invalidation) {
        let hadPending = nextFile != nil
        let time = currentTime
        let wasPlaying = node.isPlaying
        guard hadPending else {
            queue.disablePreload()
            return
        }
        queue.invalidate(reason)
        nextFile = nil
        schedule(from: frame(for: time), allowPreload: false)
        if wasPlaying {
            if !engine.isRunning { try? engine.start() }
            if engine.isRunning { node.play() }
        }
    }

    /// Called once after PlayerStore has installed a newly loaded track's queue.
    func enablePreloadForLoadedTrack() {
        queue.enablePreload()
    }

    private func schedule(from startFrame: AVAudioFramePosition, allowPreload: Bool) {
        guard let file else { return }
        let token = queue.begin(allowPreload: allowPreload)
        node.stop()
        segmentStartFrame = startFrame
        timelineStartFrame = 0
        scheduledEndFrame = file.length - startFrame
        append(file, from: startFrame, token: token)
    }

    private func append(_ file: AVAudioFile, from startFrame: AVAudioFramePosition, token: UUID) {
        let remaining = file.length - startFrame
        guard remaining > 0 else { return }
        node.scheduleSegment(file, startingFrame: startFrame,
                             frameCount: AVAudioFrameCount(remaining), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] callback in
            guard callback == .dataPlayedBack else { return }
            Task { @MainActor [weak self] in
                self?.completed(token)
            }
        }
    }

    private func completed(_ token: UUID) {
        switch queue.complete(token) {
        case .ignored: return
        case .finished: onFinish?()
        case .advanced(let id):
            guard let next = nextFile else { return }
            file = next
            nextFile = nil
            segmentStartFrame = 0
            timelineStartFrame = scheduledEndFrame
            scheduledEndFrame += next.length
            duration = Double(next.length) / next.fileFormat.sampleRate
            onAdvance?(id)
        }
    }
}
