import AVFoundation
import SwiftUI
import XCTest
@testable import LosslessPlayer

/// The native bottom accessory rebuilds its mini whenever the view that
/// applies `tabViewBottomAccessory` is re-evaluated, and a tap landing
/// during that rebuild is lost (cold-launch mini taps that never opened the
/// player). Store updates must reach the mounted mini without replacing it.
@MainActor
final class MiniAccessoryStabilityTests: XCTestCase {
    func testStoreUpdatesKeepTheMountedAccessoryMini() throws {
        guard #available(iOS 26.1, *) else { throw XCTSkip("Native bottom accessory only") }
        let (root, library, tracks) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlayerStore(library: library)
        defer { player.pause() }
        player.load(tracks[0], autoplay: false, context: tracks)
        MiniAccessoryProbe.mounts = 0
        MiniAccessoryProbe.trackID = nil

        let window = try show(LibraryView(library: library, player: player))
        defer { hide(window) }
        waitUntil("mini shows the first track") { MiniAccessoryProbe.trackID == tracks[0].id }
        flushMainQueue()
        XCTAssertEqual(MiniAccessoryProbe.mounts, 1, "Launch layout replaced the mini")

        // A library change the shell observes, then a playback change the
        // mini itself shows. Neither may replace the mounted mini.
        library.toggleFavorite(tracks[2])
        player.load(tracks[1], autoplay: false, context: tracks)
        waitUntil("mini shows the second track") { MiniAccessoryProbe.trackID == tracks[1].id }
        flushMainQueue()
        XCTAssertEqual(MiniAccessoryProbe.mounts, 1, "A store update replaced the mini")
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
