import AVFoundation

/// All envelope state and node-volume writes belong to this serial queue.
/// The unchecked conformance is limited to this queue-confined bridge; graph,
/// scheduling and play/pause APIs remain on EnginePlayer's MainActor.
final class TransportEnvelopeDriver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Lossless.transport-envelope", qos: .userInteractive)
    private let node: AVAudioPlayerNode
    private let onPerform: @MainActor @Sendable (UInt64) -> Void
    private var fader = TransportFader()
    private var timer: DispatchSourceTimer?
    private var lastTick = DispatchTime.now().uptimeNanoseconds
    private var generation: UInt64 = 0

    init(node: AVAudioPlayerNode, onPerform: @escaping @MainActor @Sendable (UInt64) -> Void) {
        self.node = node
        self.onPerform = onPerform
    }

    deinit { timer?.cancel() }

    /// Immediate work (stopped node / nested load) stays synchronous on the
    /// caller, preserving load's file/duration contract.
    func request(_ operation: TransportFader.Operation, audible: Bool) -> UInt64? {
        queue.sync {
            generation &+= 1
            let needsPerform = apply(fader.request(operation, audible: audible))
            resetClockAndDrive()
            return needsPerform ? generation : nil
        }
    }

    func isCurrent(_ token: UInt64) -> Bool { queue.sync { token == generation } }

    func performed(_ token: UInt64) {
        queue.sync {
            guard token == generation else { return }
            fader.performed()
            resetClockAndDrive()
        }
    }

    func resumeRendering() {
        queue.sync {
            generation &+= 1
            fader.resumeRendering()
            resetClockAndDrive()
        }
    }

    func invalidate() {
        queue.sync {
            generation &+= 1
            _ = apply(fader.invalidate())
            timer?.cancel()
            timer = nil
        }
    }

    private func resetClockAndDrive() {
        lastTick = DispatchTime.now().uptimeNanoseconds
        guard timer == nil, fader.isActive else { return }
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        source.schedule(deadline: .now() + .milliseconds(1), repeating: .milliseconds(1), leeway: .nanoseconds(0))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - lastTick) / 1_000_000_000
        lastTick = now
        let previousPhase = fader.phase
        let needsPerform = apply(fader.step(elapsedSeconds: elapsed))
        if fader.phase != previousPhase {
            // Anchor each hold after its actual volume write, not before it.
            lastTick = DispatchTime.now().uptimeNanoseconds
        }
        if needsPerform {
            let token = generation
            let callback = onPerform
            Task { @MainActor in callback(token) }
        }
        if !fader.isActive || fader.phase == .performing {
            timer?.cancel()
            timer = nil
        }
    }

    /// Never replay missed ticks as a burst of stale gain writes. Dispatch's
    /// 1 ms interval is a request, not a real-time guarantee; a delayed wake
    /// samples the curve at elapsed time, with holds beginning at actual writes.
    private func apply(_ events: [TransportFader.Event]) -> Bool {
        var needsPerform = false
        for event in events {
            switch event {
            case .gain(let value): node.volume = value
            case .perform: needsPerform = true
            }
        }
        return needsPerform
    }
}
