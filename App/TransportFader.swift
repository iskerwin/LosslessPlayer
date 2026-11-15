import Foundation

/// Pure transport envelope: no audio APIs or timers. Elapsed time is supplied
/// by the driver; each boundary starts at the actual zero write/action completion.
struct TransportFader {
    enum Operation: CaseIterable, Equatable {
        case pause, stop, seek, load, play, invalidatePreload

        var silence: Silence {
            switch self {
            case .load, .stop: return .reconfiguration
            default: return .renderStop
            }
        }
    }
    enum Silence {
        case renderStop, reconfiguration

        var seconds: Double {
            switch self {
            case .renderStop: return 0.040
            case .reconfiguration: return 0.120
            }
        }
    }
    enum Event: Equatable {
        case gain(Float)
        case perform(Operation)
    }
    enum Phase: Equatable { case steady, falling, holdSilent, performing, holdZero, rising }

    static let stepSeconds: Double = 0.002
    static let fadeOutSeconds: Double = 0.150
    static let fadeInSeconds: Double = 0.200
    static let zeroSeconds: Double = 0.010
    private(set) var gain: Float = 1
    private(set) var pending: Operation?
    private(set) var phase = Phase.steady
    private var elapsed: Double = 0
    private var rampStart: Float = 1
    private var silenceReady = false
    private var silence = Silence.renderStop
    var isActive: Bool { phase != .steady }

    /// Replace unfinished work without a gain jump. An already stopped node
    /// needs an explicit zero write but no new drain period. Nested load work
    /// can reuse a drained silent window, including a render restart that has
    /// not emitted its first positive gain yet.
    mutating func request(_ operation: Operation, audible: Bool, silence: Silence? = nil) -> [Event] {
        let alreadySilent = !audible || (gain == 0 && silenceReady)
        pending = operation
        self.silence = silence ?? operation.silence
        elapsed = 0
        rampStart = gain
        if alreadySilent {
            gain = 0
            return [.gain(0)] + perform()
        }
        phase = gain == 0 ? .holdSilent : .falling
        return []
    }

    /// Resume a pending pause from exactly the current gain.
    mutating func resumeRendering() {
        pending = nil
        elapsed = 0
        rampStart = gain
        phase = gain == 1 ? .steady : (gain == 0 ? .holdZero : .rising)
    }

    /// The caller acknowledges completion, including any render restart.
    /// Time waiting for the MainActor must never count toward hold-zero.
    mutating func performed() {
        guard phase == .performing else { return }
        elapsed = 0
        phase = .holdZero
    }

    mutating func step(elapsedSeconds: Double = Self.stepSeconds) -> [Event] {
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else { return [] }
        switch phase {
        case .steady, .performing: return []
        case .falling, .rising:
            let duration = phase == .falling ? Self.fadeOutSeconds : Self.fadeInSeconds
            elapsed = min(duration, elapsed + elapsedSeconds)
            // Tolerance only settles accumulated clock arithmetic at the deadline;
            // endpoint gain values are assigned exactly, never approximated by cos.
            let finished = elapsed >= duration - 1e-12
            let fraction = (1 - cos(.pi * elapsed / duration)) / 2
            if phase == .falling {
                gain = finished ? 0 : rampStart * Float(1 - fraction)
                if finished { phase = .holdSilent; elapsed = 0 }
            } else {
                gain = finished ? 1 : rampStart + (1 - rampStart) * Float(fraction)
                if finished { phase = .steady; elapsed = 0 }
            }
            if gain > 0 { silenceReady = false }
            return [.gain(gain)]
        case .holdSilent:
            elapsed += elapsedSeconds
            return elapsed >= silence.seconds - 1e-12 ? perform() : []
        case .holdZero:
            elapsed += elapsedSeconds
            if elapsed >= Self.zeroSeconds - 1e-12 {
                phase = .rising
                elapsed = 0
                rampStart = 0
            }
            return []
        }
    }

    /// Only after an external interruption has already stopped rendering.
    mutating func invalidate() -> [Event] {
        pending = nil
        phase = .steady
        elapsed = 0
        gain = 1
        silenceReady = false
        return [.gain(1)]
    }

    private mutating func perform() -> [Event] {
        guard let operation = pending else { return [] }
        pending = nil
        silenceReady = true
        phase = .performing
        elapsed = 0
        return [.perform(operation)]
    }
}
