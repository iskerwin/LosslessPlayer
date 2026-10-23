import Foundation
import AVFoundation

/// How the current output route can carry audio. Bluetooth and AirPlay always
/// re-encode or resample on the way out, so they can never be bit-perfect,
/// however good the source file is.
enum AudioRouteKind: Equatable {
    case speaker
    case wired
    case usb
    case bluetooth
    case airPlay
    case other

    static func from(_ port: AVAudioSession.Port) -> AudioRouteKind {
        switch port {
        case .builtInSpeaker: return .speaker
        case .headphones, .headsetMic, .lineOut: return .wired
        case .usbAudio: return .usb
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return .bluetooth
        case .airPlay: return .airPlay
        default: return .other
        }
    }
}

/// What the whole playback chain does to the source, judged end to end.
/// "Lossless" is a fact about the file; only `.bitPerfectPossible` is a
/// statement about the output, and even that is "possible": iOS gives no
/// public API to prove no other process mixed in, so the app never claims
/// more than the conditions it can actually check.
enum PlaybackPathLevel: Equatable {
    /// Lossless source, session rate matches the source, digital volume is
    /// 1.0, and the route is a wired or USB output that can carry the
    /// samples unchanged.
    case bitPerfectPossible
    /// Lossless source delivered at its own sample rate with no digital
    /// volume change, but the route itself (for example the built-in
    /// speaker) does not let the app promise bit-perfect output.
    case directLossless
    /// The system output rate differs from the source rate, so the samples
    /// are resampled before they reach the output.
    case resampled
    /// Bluetooth or AirPlay: the stream is re-encoded / resampled for the
    /// wireless link regardless of the source and session rates.
    case wireless
    /// Digital volume below 1.0 scales every sample, so the output is no
    /// longer the source samples even when nothing resamples them.
    case digitalVolume
    /// The source file itself is lossy; no playback chain can undo that.
    case lossySource
    /// Not enough is known yet (no track, or the session is not active).
    case unknown
}

struct AudioPathAssessment: Equatable {
    var level: PlaybackPathLevel
    var title: String
    var detail: String

    /// Judges the chain from facts the app can read: the source file, the
    /// *actual* session sample rate after activation (the preferred rate is
    /// only a request), the output route, and the engine's digital volume.
    static func assess(isLosslessSource: Bool, sourceSampleRate: Double,
                       sessionSampleRate: Double, route: AudioRouteKind,
                       digitalVolume: Float) -> AudioPathAssessment {
        guard isLosslessSource else {
            return AudioPathAssessment(level: .lossySource, title: "有损源文件",
                detail: "源文件本身是有损格式，播放链路无法还原已丢失的信息。")
        }
        if route == .bluetooth || route == .airPlay {
            return AudioPathAssessment(level: .wireless, title: "无损源 · 无线输出",
                detail: "蓝牙与 AirPlay 会对音频重新编码或重采样，无线输出无法逐位还原。")
        }
        guard digitalVolume >= 0.999 else {
            return AudioPathAssessment(level: .digitalVolume, title: "无损源 · 数字音量已缩放",
                detail: "数字音量低于 100% 会缩放每一个采样；改用输出设备的硬件音量才能保持原始采样。")
        }
        guard sessionSampleRate > 0, sourceSampleRate > 0 else {
            return AudioPathAssessment(level: .unknown, title: "输出待确认",
                detail: "音频会话尚未激活，暂时无法确认实际输出采样率。")
        }
        guard abs(sessionSampleRate - sourceSampleRate) <= 1 else {
            return AudioPathAssessment(level: .resampled, title: "无损源 · 已重采样",
                detail: "源文件为 \(Self.khz(sourceSampleRate))，系统实际输出为 \(Self.khz(sessionSampleRate))，采样已被重采样。")
        }
        if route == .usb || route == .wired {
            return AudioPathAssessment(level: .bitPerfectPossible, title: "Bit-Perfect（条件成立）",
                detail: "源文件无损、输出采样率与源文件一致、数字音量为 100% 且中间没有音效处理，采样可逐位送达有线 / USB 输出。")
        }
        return AudioPathAssessment(level: .directLossless, title: "无损直通",
            detail: "源文件无损并以原始采样率送往系统输出；该输出设备本身不提供逐位还原的保证。")
    }

    private static func khz(_ rate: Double) -> String {
        String(format: "%.1f kHz", rate / 1000)
    }
}

extension Track {
    /// Whether the file itself is lossless, from its container/codec facts.
    /// An `.m4a` is only counted when the parsed bit depth shows an ALAC-style
    /// payload; a bare extension cannot prove an m4a is not AAC.
    var isLosslessSource: Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        let lossless: Set<String> = ["flac", "alac", "wav", "aiff", "aif", "caf"]
        return lossless.contains(ext) || (ext == "m4a" && bitDepth >= 16)
    }
}
