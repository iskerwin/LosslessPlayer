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
    /// Seeks, stops and track changes bump `generation`, so a completion
    /// belonging to an older schedule never reaches this handler.
    var onFinish: (() -> Void)?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var segmentStartFrame: AVAudioFramePosition = 0
    private var generation = 0

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
        generation += 1
        node.stop()
        engine.stop()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: next.processingFormat)
        node.volume = 1.0
        engine.mainMixerNode.outputVolume = 1.0
        file = next
        duration = Double(next.length) / next.fileFormat.sampleRate
        schedule(from: frame(for: time))
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
        generation += 1
        node.stop()
        engine.stop()
        file = nil
        duration = 0
        segmentStartFrame = 0
    }

    func seek(to time: Double) {
        guard file != nil else { return }
        let wasPlaying = node.isPlaying
        schedule(from: frame(for: time))
        if wasPlaying {
            if !engine.isRunning { try? engine.start() }
            node.play()
        }
    }

    /// Playback position in seconds. `playerTime` counts samples rendered
    /// since the current segment started, so the segment's start frame is
    /// the base; when nothing has rendered yet the base alone is correct.
    var currentTime: Double {
        guard let file else { return 0 }
        let rate = file.fileFormat.sampleRate
        guard rate > 0 else { return 0 }
        let base = Double(segmentStartFrame) / rate
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return base }
        let played = Double(playerTime.sampleTime) / playerTime.sampleRate
        return min(max(0, base + played), duration)
    }

    private func frame(for time: Double) -> AVAudioFramePosition {
        guard let file, time.isFinite, time > 0 else { return 0 }
        let frame = AVAudioFramePosition(time * file.fileFormat.sampleRate)
        return min(frame, max(0, file.length - 1))
    }

    private func schedule(from startFrame: AVAudioFramePosition) {
        guard let file else { return }
        generation += 1
        let scheduled = generation
        node.stop()
        segmentStartFrame = startFrame
        let remaining = file.length - startFrame
        guard remaining > 0 else { return }
        node.scheduleSegment(file, startingFrame: startFrame,
                             frameCount: AVAudioFrameCount(remaining), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] callback in
            guard callback == .dataPlayedBack else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == scheduled else { return }
                self.onFinish?()
            }
        }
    }
}
