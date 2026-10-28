import Foundation
import AVFoundation

/// Pure comparison of decoded processing formats; no engine/session access and
/// no conversion based on library metadata or the session's preferred rate.
enum GaplessCompatibility {
    static func canJoin(_ current: AVAudioFormat, _ next: AVAudioFormat) -> Bool {
        current.sampleRate > 0 && current.channelCount > 0 &&
        current.sampleRate == next.sampleRate && current.channelCount == next.channelCount &&
        current.isEqual(next)
    }
}

/// Hardware-independent scheduling identity. Every reschedule gets a fresh
/// token so callbacks already enqueued on the main actor cannot advance it.
struct GaplessQueueState {
    enum Invalidation: CaseIterable {
        case seek, trackChange, pause, repeatChange, queueChange, interruption, routeChange
    }
    enum Completion: Equatable {
        case ignored, finished, advanced(UUID)
    }
    private(set) var currentToken: UUID?
    private(set) var pending: (id: UUID, token: UUID)?
    private(set) var allowsPreload = false

    static func nextTrack(in ids: [UUID], after current: UUID, repeatMode: RepeatMode) -> UUID? {
        guard repeatMode != .one else { return nil }
        return PlaybackQueue(ids: ids, repeatAll: repeatMode != .off).next(after: current)
    }

    mutating func begin(allowPreload: Bool = true) -> UUID {
        let token = UUID()
        currentToken = token
        pending = nil
        allowsPreload = allowPreload
        return token
    }

    mutating func enqueue(_ id: UUID) -> UUID? {
        guard allowsPreload, currentToken != nil, pending == nil else { return nil }
        let token = UUID()
        pending = (id, token)
        return token
    }

    mutating func enablePreload() {
        allowsPreload = currentToken != nil
    }

    mutating func disablePreload() {
        allowsPreload = false
    }

    mutating func invalidate(_ reason: Invalidation) {
        currentToken = nil
        pending = nil
        allowsPreload = false
    }

    mutating func complete(_ token: UUID) -> Completion {
        guard token == currentToken else { return .ignored }
        if let next = pending {
            currentToken = next.token
            pending = nil
            return .advanced(next.id)
        }
        currentToken = nil
        return .finished
    }
}
