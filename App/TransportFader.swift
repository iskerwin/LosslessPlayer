/// Pure transport envelope. The caller applies gain events in order, then runs
/// the action event. No audio APIs, timers, or listening assertions live here.
struct TransportFader {
    enum Operation: CaseIterable, Equatable {
        case pause, stop, seek, load, play, invalidatePreload
    }
    enum Event: Equatable {
        case gain(Float)
        case perform(Operation)
    }
    private enum Phase { case steady, falling, rising }

    static let stepSeconds: Double = 0.004
    static let rampSeconds: Double = 0.020
    private(set) var gain: Float = 1
    private(set) var pending: Operation?
    private var phase = Phase.steady
    var isActive: Bool { phase != .steady }

    /// New requests replace unfinished actions, retaining the current gain.
    /// A stopped node can enter the silent window immediately.
    mutating func request(_ operation: Operation, audible: Bool) -> [Event] {
        pending = operation
        phase = .falling
        if !audible {
            gain = 0
            return [.gain(0)] + enterSilence()
        }
        return gain == 0 ? enterSilence() : []
    }

    /// Resume during a pending pause reverses the envelope without a gain jump.
    mutating func resumeRendering() {
        pending = nil
        phase = gain == 1 ? .steady : .rising
    }

    mutating func step() -> [Event] {
        let delta = Float(Self.stepSeconds / Self.rampSeconds)
        switch phase {
        case .steady: return []
        case .falling:
            // Snap the final step so floating point rounding cannot strand an action.
            gain = gain <= delta + 0.000001 ? 0 : gain - delta
            return [.gain(gain)] + (gain == 0 ? enterSilence() : [])
        case .rising:
            gain = gain >= 1 - delta - 0.000001 ? 1 : gain + delta
            if gain == 1 { phase = .steady }
            return [.gain(gain)]
        }
    }

    /// Only called after rendering has been stopped by an external invalidation.
    /// Cancels stale actions and leaves the next transport at a known endpoint.
    mutating func invalidate() -> [Event] {
        pending = nil
        phase = .steady
        gain = 1
        return [.gain(1)]
    }

    private mutating func enterSilence() -> [Event] {
        guard let operation = pending else { return [] }
        pending = nil
        phase = .rising
        return [.perform(operation)]
    }
}
