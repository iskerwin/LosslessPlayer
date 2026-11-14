import Foundation
import AVFoundation

/// Lossless playback engine: `AVAudioFile` streams into an `AVAudioPlayerNode`
/// connected straight to the engine's main mixer — no EQ, no effects, no
/// converter nodes in between — with unity gain during steady playback. Only
/// transport boundaries use a short node-volume envelope; the mixer stays at 1.0.
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

    private let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private lazy var envelope = TransportEnvelopeDriver(node: node) { [weak self] token in
        self?.performTransport(token)
    }
    private var transportDepth = 0
    private var performingToken: UInt64 = 0
    private var handlingNaturalFinish = false
    private var transportAction: (() -> Void)?
    private var wantsPlayback = false
    private var pendingOperation: TransportFader.Operation?
    private var file: AVAudioFile?
    private var segmentStartFrame: AVAudioFramePosition = 0
    var onAdvance: ((UUID) -> Void)?
    private var queue = GaplessQueueState()
    private var nextFile: AVAudioFile?
    // Node time is continuous across tracks, but each track's UI clock starts at zero.
    private var timelineStartFrame: AVAudioFramePosition = 0
    private var scheduledEndFrame: AVAudioFramePosition = 0

    private(set) var duration: Double = 0
    var hasFile: Bool { file != nil && pendingOperation != .stop }
    var isPlaying: Bool { wantsPlayback }

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
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
        wantsPlayback = false
        transport(.load) { [self] in
            queue.invalidate(.trackChange)
            nextFile = nil
            // Preserve the output render stream for same-format replacements.
            if file == nil || !GaplessCompatibility.canJoin(node.outputFormat(forBus: 0), next.processingFormat) {
                node.stop()
                engine.stop()
                engine.disconnectNodeOutput(node)
                engine.connect(node, to: engine.mainMixerNode, format: next.processingFormat)
            }
            file = next
            duration = Double(next.length) / next.fileFormat.sampleRate
            schedule(from: frame(for: time), allowPreload: true)
            if !engine.isRunning { engine.prepare() }
            restartIfWanted()
        }
    }

    /// PlayerStore changes session rate only after old rendering is silent and
    /// paused. The closure includes session preparation and the new load.
    func prepareForLoad(_ action: @escaping () -> Void) {
        wantsPlayback = false
        transport(.load) { [self] in
            node.pause()
            action()
        }
    }

    /// Starts or resumes playback. Returns the accepted playback intent while
    /// an earlier transport operation finishes its silent-window work.
    @discardableResult
    func play() throws -> Bool {
        guard hasFile || pendingOperation == .load else { return false }
        if !engine.isRunning { try engine.start() }
        wantsPlayback = true
        if let operation = pendingOperation {
            // A pause that repairs an interrupted load must still rebuild the
            // segment at zero; ordinary pause/resume can reverse immediately.
            if operation != .pause || queue.currentToken == nil { return true }
            transportAction = nil
            pendingOperation = nil
        }
        if node.isPlaying {
            envelope.resumeRendering()
        } else {
            transport(.play) { [self] in node.play() }
        }
        return true
    }

    func pause() {
        wantsPlayback = false
        // Keep a pending seek/tail rebuild, but leave its result paused.
        if pendingOperation == .seek || pendingOperation == .invalidatePreload || pendingOperation == .stop { return }
        let repairCancelledLoad = pendingOperation == .load
        transport(.pause) { [self] in
            let time = currentTime
            node.pause()
            if repairCancelledLoad {
                schedule(from: frame(for: time), allowPreload: false)
            }
            restartIfWanted()
        }
    }

    func stop() {
        wantsPlayback = false
        transport(.stop) { [self] in
            queue.invalidate(.trackChange)
            nextFile = nil
            node.stop()
            engine.stop()
            file = nil
            duration = 0
            segmentStartFrame = 0
        }
    }

    func seek(to time: Double) {
        guard file != nil else { return }
        transport(.seek) { [self] in
            queue.invalidate(.seek)
            nextFile = nil
            schedule(from: frame(for: time), allowPreload: false)
            restartIfWanted()
        }
    }

    private func restartIfWanted() {
        if wantsPlayback {
            if !engine.isRunning { try? engine.start() }
            if engine.isRunning { node.play() }
        }
    }

    private func transport(_ operation: TransportFader.Operation, action: @escaping () -> Void) {
        // Reject completions from the old segment as soon as replacement is
        // requested, including callbacks queued during the fade-out.
        switch operation {
        case .load, .stop, .seek, .invalidatePreload:
            queue.invalidate(operation == .seek ? .seek : .trackChange)
            nextFile = nil
        case .pause, .play: break
        }
        // A natural end has no live segment to drain. Its existing synchronous
        // finish/load chain must stay outside the user-transport envelope.
        if handlingNaturalFinish {
            action()
            return
        }
        transportAction = action
        pendingOperation = operation
        if let token = envelope.request(operation, audible: node.isPlaying) {
            performTransport(token)
        }
    }

    private func performTransport(_ token: UInt64) {
        guard envelope.isCurrent(token) else { return }
        let action = transportAction
        transportAction = nil
        pendingOperation = nil
        transportDepth += 1
        performingToken = token
        action?()
        transportDepth -= 1
        // Session preparation -> load -> autoplay can nest synchronously.
        // Keep one silent window until the entire render restart has completed.
        if transportDepth == 0 { envelope.performed(performingToken) }
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
        let needsRebuild = nextFile != nil || (pendingOperation != nil && queue.currentToken == nil && file != nil)
        if reason == .interruption {
            // The system may already have stopped rendering. Discard any old
            // closure before restoring unity; never leave a half-faded transport.
            node.pause()
            transportAction = nil
            pendingOperation = nil
            envelope.invalidate()
            wantsPlayback = false
        }
        guard needsRebuild else {
            queue.disablePreload()
            if reason == .routeChange, wantsPlayback {
                transport(.play) { [self] in restartIfWanted() }
            }
            return
        }
        transport(.invalidatePreload) { [self] in
            let time = currentTime
            queue.invalidate(reason)
            nextFile = nil
            schedule(from: frame(for: time), allowPreload: false)
            restartIfWanted()
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
        case .finished:
            handlingNaturalFinish = true
            defer { handlingNaturalFinish = false }
            onFinish?()
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
