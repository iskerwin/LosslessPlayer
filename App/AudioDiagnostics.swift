import AVFoundation
import SwiftUI
import UIKit

/// Diagnostic build only (branch exp/pop-diagnostics, never merged).
/// Reads the mixed output through a tap and logs session events; it never
/// changes the audio.
@MainActor
final class AudioDiagnostics: ObservableObject {
    static let shared = AudioDiagnostics()
    @Published private(set) var lines: [String] = []
    private let analyzer = OutputAnalyzer()
    private let started = ProcessInfo.processInfo.systemUptime
    private var observers: [NSObjectProtocol] = []

    func attach(_ engine: AVAudioEngine) {
        analyzer.install(on: engine)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: .main) { [weak self, weak engine] _ in
            MainActor.assumeIsolated {
                self?.log("引擎配置变化，running=\(engine?.isRunning ?? false)；\(Self.sessionSummary())")
                if let engine { self?.analyzer.install(on: engine) }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                self?.log("路由变化 \(Self.routeReason(reason))；\(Self.sessionSummary())")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            MainActor.assumeIsolated { self?.log("会话中断 type=\(type)") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.log("媒体服务重置") }
        })
        log("诊断已启动；\(Self.sessionSummary())")
    }

    func log(_ text: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        lines.append(String(format: "%7.2fs ", elapsed) + text)
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
    }

    func clear() { lines.removeAll() }

    /// Marks a transport event and reports the output around it 1.5 s later.
    func mark(_ event: String) {
        let time = ProcessInfo.processInfo.systemUptime
        log("▶ \(event)；\(Self.sessionSummary())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.report(event, at: time) }
        }
    }

    private func report(_ event: String, at time: TimeInterval) {
        let before = analyzer.blocks(from: time - 1.0, to: time)
        let after = analyzer.blocks(from: time, to: time + 1.3)
        guard let worst = after.max(by: { $0.maxJump < $1.maxJump }) else {
            log("  \(event)：之后 1.3 秒没有输出数据")
            return
        }
        let baseline = before.map(\.maxJump).max() ?? 0
        var gaps: [String] = []
        for (a, b) in zip(after, after.dropFirst()) {
            let expected = Double(a.frames) / max(1, a.rate)
            let interval = b.time - a.time
            if interval > expected * 2.5 + 0.02 {
                gaps.append(String(format: "%.0fms@+%.0fms", interval * 1000, (a.time - time) * 1000))
            }
        }
        let ratio = baseline > 0 ? worst.maxJump / baseline : 0
        log(String(format: "  %@：最大跳变 %.4f（之前 1 秒 %.4f，×%.1f）在 +%.0fms；块 %ld 帧 @%.0fHz；输出间断：%@",
                   event, worst.maxJump, baseline, ratio, (worst.time - time) * 1000, worst.frames, worst.rate,
                   gaps.isEmpty ? "无" : gaps.joined(separator: ", ")))
        let peaks = after.prefix(40).map { String(format: "%.2f", $0.peak) }.joined(separator: " ")
        log("  峰值 [\(peaks)]")
    }

    func sessionActivation(categoryChanged: Bool, preferredRate: Double?, activate: Bool) {
        var parts: [String] = []
        if categoryChanged { parts.append("设置类别") }
        if let preferredRate { parts.append(String(format: "首选采样率 %.0f", preferredRate)) }
        if activate { parts.append("setActive(true)") }
        guard !parts.isEmpty else { return }
        log("会话：" + parts.joined(separator: "，") + "；\(Self.sessionSummary())")
    }

    nonisolated static func sessionSummary() -> String {
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.outputs.first?.portType.rawValue ?? "none"
        return String(format: "输出 %@ · %.0fHz · IO %.1fms · 延迟 %.1fms", port, session.sampleRate,
                      session.ioBufferDuration * 1000, session.outputLatency * 1000)
    }

    nonisolated static func routeReason(_ raw: UInt) -> String {
        switch AVAudioSession.RouteChangeReason(rawValue: raw) {
        case .newDeviceAvailable: return "新设备"
        case .oldDeviceUnavailable: return "设备断开"
        case .categoryChange: return "类别变化"
        case .override: return "覆盖"
        case .wakeFromSleep: return "唤醒"
        case .noSuitableRouteForCategory: return "无可用路由"
        case .routeConfigurationChange: return "路由配置变化"
        default: return "未知(\(raw))"
        }
    }

    /// Two 60 s tones, imported like ordinary files so playback takes the
    /// app's real path. A tone makes any jump in the output measurable.
    static func importTestTones(into library: LibraryStore) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lossless-test-tones")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (name, frequency) in [("Lossless 测试音 A", 220.0), ("Lossless 测试音 B", 330.0)] {
            let url = folder.appendingPathComponent(name + ".wav")
            if writeTone(to: url, frequency: frequency) { urls.append(url) }
        }
        shared.log("生成测试音 \(urls.count) 个，开始导入")
        await library.importFiles(urls)
        shared.log("导入完成：\(library.scanSummary ?? "")")
    }

    private static func writeTone(to url: URL, frequency: Double) -> Bool {
        let rate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                          interleaved: false) else { return false }
        let frames = AVAudioFrameCount(rate * 60)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return false }
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for index in 0..<Int(frames) {
                data[index] = 0.5 * Float(sin(2 * Double.pi * frequency * Double(index) / rate))
            }
        }
        return (try? file.write(from: buffer)) != nil
    }
}

/// Per-block statistics of the main mixer's output, read on the tap thread.
final class OutputAnalyzer: @unchecked Sendable {
    struct Block {
        var time: TimeInterval
        var maxJump: Float
        var peak: Float
        var rate: Double
        var frames: Int
    }

    private let lock = NSLock()
    private var recorded: [Block] = []
    private var lastSample: Float?

    func install(on engine: AVAudioEngine) {
        let mixer = engine.mainMixerNode
        mixer.removeTap(onBus: 0)
        lock.lock(); lastSample = nil; lock.unlock()
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        let samples = channels[0]
        lock.lock(); var previous = lastSample; lock.unlock()
        var maxJump: Float = 0
        var peak: Float = 0
        for index in 0..<count {
            let value = samples[index]
            peak = max(peak, abs(value))
            if let previous { maxJump = max(maxJump, abs(value - previous)) }
            previous = value
        }
        let block = Block(time: ProcessInfo.processInfo.systemUptime, maxJump: maxJump, peak: peak,
                          rate: buffer.format.sampleRate, frames: count)
        lock.lock()
        lastSample = previous
        recorded.append(block)
        if recorded.count > 3000 { recorded.removeFirst(recorded.count - 3000) }
        lock.unlock()
    }

    func blocks(from start: TimeInterval, to end: TimeInterval) -> [Block] {
        lock.lock(); defer { lock.unlock() }
        return recorded.filter { $0.time >= start && $0.time < end }
    }
}

struct AudioDiagnosticsView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var diagnostics = AudioDiagnostics.shared
    @State private var importing = false

    var body: some View {
        List {
            Section {
                Button("导入测试音 A / B", systemImage: "waveform") {
                    importing = true
                    Task {
                        await AudioDiagnostics.importTestTones(into: library)
                        importing = false
                    }
                }
                .disabled(importing || library.importing)
                Button("复制日志", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = diagnostics.lines.joined(separator: "\n")
                }
                Button("清空日志", systemImage: "trash", role: .destructive) { diagnostics.clear() }
            } footer: {
                Text("诊断版：只读取输出，不改变声音。在歌曲里搜索“测试音”播放，然后暂停、恢复、切歌各做几次，再复制日志。")
            }
            Section("日志") {
                ForEach(Array(diagnostics.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("音频诊断")
    }
}
