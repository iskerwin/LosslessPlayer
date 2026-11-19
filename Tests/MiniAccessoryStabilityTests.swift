import AVFoundation
import SwiftUI
import XCTest
@testable import LosslessPlayer

/// The native bottom accessory replaces its mini whenever the view that
/// applies `tabViewBottomAccessory` re-runs its body, and a tap landing
/// during the swap is lost (cold-launch mini taps that never opened the
/// player). Run 43708252094 traced the app root re-running at launch and
/// right as the first touch arrived. Every update below must reach the
/// mounted mini without replacing it.
@MainActor
final class MiniAccessoryStabilityTests: XCTestCase {
    func testStoreUpdatesKeepTheMountedAccessoryMini() throws {
        try assertMiniSurvives(.storeUpdate)
    }

    func testParentReRenderKeepsTheMountedAccessoryMini() throws {
        try assertMiniSurvives(.reRender)
    }

    func testParentEnvironmentChangeKeepsTheMountedAccessoryMini() throws {
        try assertMiniSurvives(.environment)
    }

    func testScenePhaseChangeKeepsTheMountedAccessoryMini() throws {
        try assertMiniSurvives(.scenePhase)
    }

    func testKeyWindowChangeKeepsTheMountedAccessoryMini() throws {
        try assertMiniSurvives(.keyWindow)
    }

    /// A mini from another window, like an earlier test's while it tears
    /// down, can still report after `reset()`. Run 43811026418 counted one
    /// against the mini under test and failed with nothing replaced.
    func testProbeIgnoresTheMiniOfAnotherPlayer() throws {
        guard #available(iOS 26.1, *) else { throw XCTSkip("Native bottom accessory only") }
        let (root, library, tracks) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let earlier = PlayerStore(library: library)
        defer { earlier.pause() }
        earlier.load(tracks[2], autoplay: false, context: tracks)
        let earlierWindow = try show(LibraryView(library: library, player: earlier))
        let originalKey = displacedKey
        waitUntil("earlier mini shows its track") { MiniAccessoryProbe.trackID(for: earlier) == tracks[2].id }

        MiniAccessoryProbe.reset()
        let player = PlayerStore(library: library)
        defer { player.pause() }
        player.load(tracks[0], autoplay: false, context: tracks)
        let window = try show(LibraryView(library: library, player: player))
        waitUntil("mini shows the first track") { MiniAccessoryProbe.trackID(for: player) == tracks[0].id }
        earlier.load(tracks[1], autoplay: false, context: tracks)
        waitUntil("earlier mini shows its next track") { MiniAccessoryProbe.trackID(for: earlier) == tracks[1].id }
        flushMainQueue()

        XCTAssertEqual(MiniAccessoryProbe.trackID(for: player), tracks[0].id)
        XCTAssertEqual(MiniAccessoryProbe.instances(for: player).count, 1)
        hide(window)
        displacedKey = originalKey
        hide(earlierWindow)
    }

    /// The shell is compared byte by byte, gaps included, and a gap holds
    /// leftover data: a Bool stored ahead of a reference re-ran the shell on
    /// updates that changed nothing, in about half of all runs (8 of 8 with an
    /// extra state in LibraryView), replacing the mini each time.
    func testShellStoresItsFieldsWithoutGaps() {
        XCTAssertEqual(LibraryTabsLayout.unusedBytes, 0)
    }

    /// The player zooms from the native accessory, found from UIKit, since
    /// nothing inside the accessory may be a UIKit view.
    func testPlayerZoomSourceIsTheNativeAccessory() throws {
        guard #available(iOS 26.1, *) else { throw XCTSkip("Native bottom accessory only") }
        let (root, library, tracks) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlayerStore(library: library)
        defer { player.pause() }
        player.load(tracks[0], autoplay: false, context: tracks)
        MiniAccessoryProbe.reset()

        let window = try show(LibraryView(library: library, player: player))
        defer { hide(window) }
        waitUntil("mini shows the first track") { MiniAccessoryProbe.trackID(for: player) == tracks[0].id }
        flushMainQueue()
        let source = try XCTUnwrap(PlayerZoomAnchor().source(in: window), "No native accessory to zoom from")
        XCTAssertTrue(source.window === window)
        let frame = source.convert(source.bounds, to: window)
        XCTAssertFalse(frame.isEmpty)
        XCTAssertTrue(window.bounds.contains(frame), "\(frame) is outside the window \(window.bounds)")
        XCTAssertGreaterThan(frame.minY, window.bounds.midY, "\(frame) is not at the bottom of the window")
    }

    private func assertMiniSurvives(_ trigger: ParentTrigger, file: StaticString = #filePath,
                                    line: UInt = #line) throws {
        guard #available(iOS 26.1, *) else { throw XCTSkip("Native bottom accessory only") }
        let (root, library, tracks) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlayerStore(library: library)
        defer { player.pause() }
        player.load(tracks[0], autoplay: false, context: tracks)
        MiniAccessoryProbe.reset()
        let parent = ParentProbe()

        let window = try show(ParentHarness(probe: parent, trigger: trigger, library: library, player: player))
        defer { hide(window) }
        waitUntil("mini shows the first track") { MiniAccessoryProbe.trackID(for: player) == tracks[0].id }
        flushMainQueue()
        XCTAssertEqual(MiniAccessoryProbe.instances(for: player).count, 1, "Launch layout replaced the mini", file: file, line: line)

        for round in 1...2 {
            switch trigger {
            case .storeUpdate:
                // A library change the shell observes, then a playback change
                // the mini itself shows.
                library.toggleFavorite(tracks[2])
                let next = tracks[round % 2]
                player.load(next, autoplay: false, context: tracks)
                waitUntil("mini shows the next track") { MiniAccessoryProbe.trackID(for: player) == next.id }
            case .keyWindow:
                let other = UIWindow(windowScene: try XCTUnwrap(window.windowScene))
                other.makeKeyAndVisible()
                flushMainQueue()
                other.isHidden = true
                window.makeKeyAndVisible()
            case .reRender, .environment, .scenePhase:
                let seen = parent.evaluations
                parent.tick += 1
                waitUntil("parent re-ran") { parent.evaluations > seen }
            }
            flushMainQueue()
        }
        XCTAssertEqual(MiniAccessoryProbe.instances(for: player).count, 1, "\(trigger) replaced the mini", file: file, line: line)
    }

    private func fixture() throws -> (URL, LibraryStore, [Track]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000
        for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = 0 }
        var tracks: [Track] = []
        for name in ["First", "Second", "Third"] {
            let filename = name + ".wav"
            do {
                let file = try AVAudioFile(forWriting: root.appendingPathComponent(filename), settings: format.settings)
                try file.write(from: buffer)
            }
            tracks.append(Track(id: UUID(), filename: filename, title: name, artist: "Artist", album: "Album",
                                duration: 1, sampleRate: 8000, bitDepth: 16))
        }
        var snapshot = LibrarySnapshot()
        snapshot.tracks = tracks
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("library.json"))
        return (root, LibraryStore(root: root), tracks)
    }

    private var displacedKey: UIWindow?

    private func show<Content: View>(_ root: Content) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        displacedKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return window
    }

    private func hide(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
        displacedKey?.makeKeyAndVisible()
        displacedKey = nil
    }

    /// Runs the main queue, where SwiftUI commits, until `condition` holds.
    /// The timeout only bounds a failure; it is not the pass condition.
    private func waitUntil(_ description: String, _ condition: @escaping () -> Bool) {
        let done = expectation(description: description)
        func poll() {
            if condition() { done.fulfill() } else { DispatchQueue.main.async(execute: poll) }
        }
        DispatchQueue.main.async(execute: poll)
        wait(for: [done], timeout: 5)
    }

    /// One more main-queue turn, so a replacement mounted in the same commit
    /// as the update has also run its `onAppear`.
    private func flushMainQueue() {
        let turned = expectation(description: "main queue turned")
        DispatchQueue.main.async { DispatchQueue.main.async { turned.fulfill() } }
        wait(for: [turned], timeout: 5)
    }
}

private enum ParentTrigger { case storeUpdate, reRender, environment, scenePhase, keyWindow }

private final class ParentProbe: ObservableObject {
    @Published var tick = 0
    var evaluations = 0
}

private struct ParentTickKey: EnvironmentKey { static let defaultValue = 0 }

private extension EnvironmentValues {
    var parentTick: Int {
        get { self[ParentTickKey.self] }
        set { self[ParentTickKey.self] = newValue }
    }
}

/// Stands in for the App body above LibraryView.
private struct ParentHarness: View {
    @ObservedObject var probe: ParentProbe
    let trigger: ParentTrigger
    let library: LibraryStore
    let player: PlayerStore

    var body: some View {
        let _ = probe.evaluations += 1
        let tick = probe.tick
        switch trigger {
        case .environment:
            LibraryView(library: library, player: player).environment(\.parentTick, tick)
        case .scenePhase:
            LibraryView(library: library, player: player).environment(\.scenePhase, tick % 2 == 1 ? .inactive : .active)
        case .storeUpdate, .reRender, .keyWindow:
            LibraryView(library: library, player: player)
        }
    }
}
