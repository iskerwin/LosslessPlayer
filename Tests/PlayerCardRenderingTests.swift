import XCTest
import SwiftUI
import UIKit
@testable import LosslessPlayer

/// Recreates the old inner List traits and 8 pt vertical padding without
/// changing production geometry or adding a diagnostic app launch mode.
private struct LegacySongInsetsProbe: View, Equatable {
    let track: Track

    var body: some View {
        SongContextRow(track: track, root: FileManager.default.temporaryDirectory, handlers: .ignore)
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }
}

@MainActor
final class PlayerCardRenderingTests: XCTestCase {
    func testSongRowHeightIs56PointsAndGrowsWithDynamicType() throws {
        let track = Track(id: UUID(), filename: "row.wav", title: "Song", artist: "Artist",
                          album: "Album", duration: 1, sampleRate: 44100, bitDepth: 16)
        func height(at size: DynamicTypeSize) throws -> Int {
            let renderer = ImageRenderer(content:
                SongRow(track: track, root: FileManager.default.temporaryDirectory)
                    .environment(\.dynamicTypeSize, size)
                    .frame(width: 320)
                    .fixedSize(horizontal: false, vertical: true)
            )
            renderer.scale = 1
            return try XCTUnwrap(renderer.cgImage).height
        }
        XCTAssertEqual(try height(at: .large), 56)
        XCTAssertGreaterThan(try height(at: .accessibility5), 56)
    }

    func testSongListBoundaryInsetsRemoveSystemVerticalPadding() async throws {
        let track = Track(id: UUID(), filename: "row.wav", title: "Song", artist: "Artist",
                          album: "Album", duration: 1, sampleRate: 44100, bitDepth: 16)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let originalKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalKey?.makeKeyAndVisible()
        }
        func collection(in view: UIView) -> UICollectionView? {
            if let collection = view as? UICollectionView { return collection }
            return view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        var heights: [CGFloat] = []
        for boundaryInsets in [false, true] {
            let row = LegacySongInsetsProbe(track: track)
                .equatable()
                .swipeActions(edge: .trailing) { Button("Delete") {} }
                .swipeActions(edge: .leading) { Button("Favorite") {} }
            let host = UIHostingController(rootView:
                List {
                    if boundaryInsets {
                        row.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    } else {
                        row.listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .environment(\.dynamicTypeSize, .large)
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            // Allow the real List collection view to create and size its cell.
            try await Task.sleep(for: .milliseconds(250))
            host.view.layoutIfNeeded()
            let cell = try XCTUnwrap(collection(in: host.view)?.visibleCells.first)
            heights.append(cell.frame.height)
        }
        let measurements = "Legacy nested insets: \(heights[0])pt; boundary insets: \(heights[1])pt"
        print(measurements)
        let attachment = XCTAttachment(string: measurements)
        attachment.name = "song-list-inset-layer-measurements"
        attachment.lifetime = .keepAlways
        add(attachment)
        // The probe restores the old 8 pt padding: its content is exactly 64 pt.
        XCTAssertEqual(heights[1], 64, accuracy: 0.5)
        XCTAssertGreaterThan(heights[0], heights[1], "Nested traits must reproduce the extra List padding")
    }

    // Draw into the full-size bitmap before indexing top-left image rows.
    // Translating the image into a one-pixel CGContext instead samples in
    // Core Graphics' bottom-left coordinates, away from a collapsed card.
    private func rgbaPixels(in image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    func testPixelSamplerUsesTopLeftImageCoordinates() throws {
        let renderer = ImageRenderer(content:
            VStack(spacing: 0) {
                Color(red: 1, green: 0, blue: 0).frame(height: 3)
                Color(red: 0, green: 0, blue: 1).frame(height: 5)
            }.frame(width: 4)
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let pixels = try rgbaPixels(in: image)
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 8)
        for y in 0..<image.height {
            let offset = (y * image.width + 2) * 4
            XCTAssertEqual(Array(pixels[offset..<(offset + 4)]),
                           y < 3 ? [255, 0, 0, 255] : [0, 0, 255, 255], "Row \(y)")
        }
    }

    func testArtworkFillsTopStripAndSharesCardClipAtDragAndSpringProgress() throws {
        let mini = CGRect(x: 12, y: 600, width: 336, height: 56)
        let expanded = CGRect(x: 0, y: 0, width: 360, height: 720)
        let texture = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        for scheme in [ColorScheme.light, .dark] {
            // Includes the landing handover with hidden expanded controls,
            // intermediate drag frames and spring overshoot. No timer drives these samples.
            for progress in [CGFloat(0.03), 0.045, 0.06, 0.1, 0.25, 0.3, 0.5, 0.8, 0.95, 1, 1.05] {
                let frame = PlayerCardMetrics.frame(progress: progress, mini: mini, expanded: expanded)
                let card = PlayerCard(progress: progress, miniFrame: mini, expandedFrame: expanded,
                                      reduceMotion: false, canReopen: false, onReopen: {}) {
                    ArtworkBackdrop(colors: [.green], image: texture, extendsIntoSafeArea: false)
                } expanded: {
                    // Reproduce the presenter's safe-area padding without
                    // introducing any foreground pixels into the sampled strip.
                    Color.clear.padding(.top, 59).padding(.bottom, 34)
                } collapsed: {
                    Color.red
                }
                let renderer = ImageRenderer(content:
                    Color(red: 0, green: 0, blue: 1)
                        .frame(width: 360, height: 720)
                        .overlay(alignment: .topLeading) { card }
                        .environment(\.colorScheme, scheme)
                )
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                // Normalize pixel layout instead of depending on CGImage's
                // byte order or premultiplied-alpha representation.
                let pixels = try rgbaPixels(in: image)
                func channel(_ x: CGFloat, _ y: CGFloat, _ component: Int) -> UInt8 {
                    pixels[(Int(y) * image.width + Int(x)) * 4 + component]
                }
                let middle = frame.midX
                let nearCorner = frame.minX + PlayerCardMetrics.topRadius(progress) + 2
                for x in [middle, nearCorner] {
                    for y in [frame.minY + 2, frame.minY + 30, frame.minY + 60] {
                        XCTAssertGreaterThan(channel(x, y, 1), 120, "Missing artwork at \(progress), \(scheme)")
                        XCTAssertLessThan(channel(x, y, 0), 40, "Material strip at \(progress), \(scheme)")
                        XCTAssertLessThan(channel(x, y, 2), 40)
                    }
                }
                // Only the blue underlying page is visible through the corner;
                // the oversized scaled-to-fill texture must not escape the clip.
                XCTAssertGreaterThan(channel(frame.minX + 1, frame.minY + 1, 2), 240)
                XCTAssertLessThan(channel(frame.minX + 1, frame.minY + 1, 1), 15)
            }
        }
    }

    func testCollapseCropsFullSizeBackdropWithoutCompressingDarkLowerRegion() throws {
        let mini = CGRect(x: 12, y: 600, width: 336, height: 56)
        let expanded = CGRect(x: 0, y: 0, width: 360, height: 720)
        // An abrupt lower band makes compression unmistakable. The production
        // backdrop has a gradual dark lower gradient; both must remain in the
        // same full-screen coordinates as the expanded controls.
        let backdrop = GeometryReader { geometry in
            VStack(spacing: 0) {
                // Color.green is adaptive system green (52/199/89 in light),
                // not the pure RGB green required by these channel assertions.
                Color(red: 0, green: 1, blue: 0).frame(height: geometry.size.height * 0.75)
                Color.black
            }
        }
        for scheme in [ColorScheme.light, .dark] {
            for progress in [CGFloat(0.03), 0.06, 0.25, 0.5, 0.7, 0.9] {
                let frame = PlayerCardMetrics.frame(progress: progress, mini: mini, expanded: expanded)
                let card = PlayerCard(progress: progress, miniFrame: mini, expandedFrame: expanded,
                                      reduceMotion: false, canReopen: false, onReopen: {}) {
                    backdrop
                } expanded: { Color.clear } collapsed: { Color.red }
                let renderer = ImageRenderer(content:
                    Color.blue.frame(width: 360, height: 720)
                        .overlay(alignment: .topLeading) { card }
                        .environment(\.colorScheme, scheme))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                let pixels = try rgbaPixels(in: image)
                for fraction in [CGFloat(0.1), 0.4, 0.7, 0.9] {
                    let localY = frame.height * fraction
                    let offset = (Int(frame.minY + localY) * image.width + Int(frame.midX)) * 4
                    // Allow three 8-bit levels for rasterization. A lower dark
                    // region above its original y=540 fails the green channel.
                    let expected: Double = localY < 540 ? 255 : 0
                    XCTAssertEqual(Double(pixels[offset + 1]), expected, accuracy: 3,
                                   "Backdrop reflow at progress \(progress), fraction \(fraction), \(scheme)")
                    XCTAssertLessThan(pixels[offset], 4)
                    XCTAssertLessThan(pixels[offset + 2], 4)
                }
            }
        }
    }

    func testSharedArtworkBackgroundPreservesTextureHueAndOpaqueEdgesInBothAppearances() throws {
        let fixtures: [(String, UIImage?)] = [
            ("warm", washFixture(top: .red, bottom: .yellow)),
            ("cool", washFixture(top: .blue, bottom: .cyan)),
            ("neutral", washFixture(top: .black, bottom: .white)),
            ("missing", nil)
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, texture) in fixtures {
                let renderer = ImageRenderer(content: ArtworkBackgroundSurface(analysis: texture.map { ArtworkAnalysis.make(from: $0) }, followsAppearance: true)
                    .frame(width: 360, height: 720).environment(\.colorScheme, scheme))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                let pixels = try rgbaPixels(in: image)
                var samples: [[UInt8]] = []
                // Top/bottom edges and list region must all be opaque wash.
                for y in [0, 180, 540, 719] {
                    let offset = (y * image.width + 180) * 4
                    let rgb = Array(pixels[offset..<(offset + 3)])
                    XCTAssertEqual(pixels[offset + 3], 255, "Edge leak: \(name), \(scheme), \(y)")
                    for channel in rgb {
                        if scheme == .light {
                            XCTAssertGreaterThanOrEqual(channel, 205, "Light wash became dark")
                        } else {
                            XCTAssertLessThanOrEqual(channel, 75, "Dark wash is too bright")
                        }
                    }
                    if name == "warm" { XCTAssertGreaterThan(Int(rgb[0]) - Int(rgb[2]), 15) }
                    if name == "cool" { XCTAssertGreaterThan(Int(rgb[2]) - Int(rgb[0]), 15) }
                    if name == "neutral" {
                        XCTAssertEqual(Double(rgb[0]), Double(rgb[2]), accuracy: 2)
                    }
                    samples.append(rgb)
                }
                let variation = (0..<3).map { channel in
                    Int(samples.map { $0[channel] }.max()!) - Int(samples.map { $0[channel] }.min()!)
                }.max()!
                XCTAssertGreaterThan(variation, 5, "Flat plate instead of texture: \(name), \(scheme)")
            }
        }
    }

    func testLandedPlayerAddsNoBackingOverAccessorySurface() throws {
        // The native accessory (or legacy inset) already owns the material.
        // Transparent travelling content must not add a second surface even
        // while the spring completion has not yet unmounted the card.
        for scheme in [ColorScheme.light, .dark] {
            for height in [CGFloat(36), 56] {
                for reduced in [false, true] {
                    let mini = CGRect(x: 12, y: 600, width: 336, height: height)
                    let renderer = ImageRenderer(content:
                        Color(red: 1, green: 0, blue: 1).frame(width: 360, height: 720)
                            .overlay(alignment: .topLeading) {
                                PlayerCard(progress: 0, miniFrame: mini,
                                    expandedFrame: CGRect(x: 0, y: 0, width: 360, height: 720),
                                    reduceMotion: reduced, canReopen: false, onReopen: {}) {
                                        Color.black
                                    } expanded: { Color.black } collapsed: { Color.clear }
                            }
                            .environment(\.colorScheme, scheme))
                    renderer.scale = 1
                    let image = try XCTUnwrap(renderer.cgImage)
                    let pixels = try rgbaPixels(in: image)
                    for x in [30, 180, 330] {
                        let offset = (Int(mini.midY) * image.width + x) * 4
                        let expected = [255, 0, 255, 255]
                        for channel in 0..<4 {
                            XCTAssertEqual(Int(pixels[offset + channel]), expected[channel], accuracy: 2)
                        }
                    }
                }
            }
        }
    }

    private func washFixture(top: UIColor, bottom: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { context in
            top.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
            bottom.setFill()
            context.fill(CGRect(x: 0, y: 60, width: 120, height: 60))
        }
    }

    func testNativeCollectionPushDoesNotChangeLightWindowAppearance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let player = PlayerStore(library: library)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let originalKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalKey?.makeKeyAndVisible()
        }
        let page = CollectionPage(library: library, player: player, title: "Album", tracks: [], kind: .album,
            onOpen: { _ in }, onAddToPlaylist: { _ in }, onDelete: { _ in }, onLyrics: { _ in })
        let detail = DetailZoomRoute(route: .album("appearance"), grid: .albumIndex)
        for pushed in [false, true, false] {
            let host = UIHostingController(rootView:
                NativeCollectionAppearanceHarness(page: page, detail: detail, pushed: pushed))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            // Let SwiftUI propagate presentation preferences through UIKit.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(host.traitCollection.userInterfaceStyle, .light,
                           "Collection preference escaped native navigation (pushed: \(pushed))")
            XCTAssertEqual(window.overrideUserInterfaceStyle, .light)
        }
    }

    func testDetailReturnHasNoDelayedAppearanceChange() async throws {
        for kind in [CollectionPage.Kind.album, .playlist] {
            try await checkReturnAppearance(kind: kind)
        }
    }

    func testPlayerReturnHasNoDelayedAppearanceChange() async throws {
        try await checkReturnAppearance(kind: nil)
    }

    /// Keep one window, controller and SwiftUI identity for the entire sequence.
    /// Replacing the controller per sample would discard a lingering preference.
    private func checkReturnAppearance(kind: CollectionPage.Kind?) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let player = PlayerStore(library: library)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let originalKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalKey?.makeKeyAndVisible()
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            let state = ReturnAppearanceState()
            let baseProbe = AppearanceProbeView()
            let contentProbe = AppearanceProbeView()
            let host = UIHostingController(rootView: ReturnAppearanceHarness(
                state: state, library: library, player: player, kind: kind,
                baseProbe: baseProbe, contentProbe: contentProbe))
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(100))

            func sample(_ phase: String, contentVisible: Bool) throws {
                host.view.layoutIfNeeded()
                let expected: ColorScheme = style == .light ? .light : .dark
                let context = "\(String(describing: kind)), \(style.rawValue), \(phase)"
                XCTAssertEqual(host.traitCollection.userInterfaceStyle, style, context)
                XCTAssertEqual(baseProbe.scheme, expected, context)
                if contentVisible {
                    // Detail inherits the system; expanded player stays dark by design.
                    XCTAssertEqual(contentProbe.scheme, kind == nil ? .dark : expected, context)
                }
                let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8),
                    format: UIGraphicsImageRendererFormat.default()).image { renderer in
                    baseProbe.layer.render(in: renderer.cgContext)
                }
                let cgImage = try XCTUnwrap(image.cgImage)
                let pixels = try rgbaPixels(in: cgImage)
                let offset = ((cgImage.height / 2) * cgImage.width + cgImage.width / 2) * 4
                for channel in 0..<3 {
                    if style == .light {
                        XCTAssertGreaterThan(pixels[offset + channel], 245, context)
                    } else {
                        XCTAssertLessThan(pixels[offset + channel], 8, context)
                    }
                }
            }
            try sample("before opening", contentVisible: false)
            state.mounted = true
            if kind != nil {
                state.detailPath = [DetailZoomRoute(route: .album("appearance"), grid: .albumIndex)]
            }
            for progress in [CGFloat(0), 0.5, 1] {
                state.progress = progress
                try await Task.sleep(for: .milliseconds(100))
                try sample("opening \(progress)", contentVisible: true)
            }
            for progress in [CGFloat(0.5), 0] {
                state.progress = progress
                try await Task.sleep(for: .milliseconds(100))
                try sample("closing \(progress), still mounted", contentVisible: true)
            }
            state.mounted = false
            state.detailPath = []
            // First rendered return frame, then 0.5, 1 and 1.5 seconds from it.
            // Test-only waits observe retention; production has no delayed reset.
            try await Task.sleep(for: .milliseconds(20))
            try sample("first return frame", contentVisible: false)
            for milliseconds in [500, 1000, 1500] {
                try await Task.sleep(for: .milliseconds(500))
                try sample("returned \(milliseconds) ms", contentVisible: false)
            }
        }
    }

    func testExpandedContentStaysOpaqueUntilLandingHandover() throws {
        let mini = CGRect(x: 12, y: 600, width: 336, height: 56)
        let expanded = CGRect(x: 0, y: 0, width: 360, height: 720)
        for scheme in [ColorScheme.light, .dark] {
            // Render both resting states, serial handover, former fade windows,
            // and overshoot. Sample inside the clip, away from rounded edges.
            for progress in [CGFloat(-0.05), 0, 0.03, 0.045, 0.06, 0.1, 0.25, 0.3, 0.5, 0.65, 1, 1.05] {
                let frame = PlayerCardMetrics.frame(progress: progress, mini: mini, expanded: expanded)
                let card = PlayerCard(progress: progress, miniFrame: mini, expandedFrame: expanded,
                                      reduceMotion: false, canReopen: false, onReopen: {}) {
                    Color(red: 0, green: 1, blue: 0)
                } expanded: {
                    Color(red: 1, green: 0, blue: 0)
                } collapsed: {
                    Color(red: 0, green: 0, blue: 1)
                }
                let renderer = ImageRenderer(content:
                    Color.white.frame(width: 360, height: 720)
                        .overlay(alignment: .topLeading) { card }
                        .environment(\.colorScheme, scheme)
                )
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                let pixels = try rgbaPixels(in: image)
                let offset = (Int(frame.minY + 28) * image.width + Int(frame.midX)) * 4
                let pixel = Array(pixels[offset..<(offset + 4)])
                let expected: [UInt8]
                if progress <= 0 {
                    expected = [0, 0, 255] // Mini owns the landed card, including overshoot.
                } else if progress == 0.03 {
                    expected = [0, 255, 0] // Continuous background between serial content fades.
                } else if progress < 0.06 {
                    expected = [128, 128, 0] // Expanded fades only immediately before landing.
                } else {
                    expected = [255, 0, 0] // Expanded stays fully opaque throughout travel.
                }
                for component in 0..<3 {
                    XCTAssertEqual(Double(pixel[component]), Double(expected[component]), accuracy: 3,
                                   "Wrong content at \(progress), \(scheme), channel \(component)")
                }
            }
        }
    }

    func testLibraryShellDoesNotStoreCardProgress() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/LibraryView.swift"), encoding: .utf8)
        XCTAssertNil(source.range(of: "playerProgress"))
        XCTAssertNil(source.range(of: "detailProgress"))
        XCTAssertNotNil(source.range(of: "PlayerMotionHost"))
        XCTAssertNil(source.range(of: "DetailMotionHost"))
    }

    func testPlayerProgressWritesDoNotEvaluateTheShell() throws {
        let probe = TransitionEvaluationProbe()
        let bridge = PlayerGestureBridge()
        let ready = expectation(description: "player card appeared")
        let window = try show(PlayerShellProbe(probe: probe, bridge: bridge, ready: {
            guard !probe.didReady else { return }
            probe.didReady = true
            ready.fulfill()
        }))
        defer { hide(window) }
        wait(for: [ready], timeout: 2)
        let shellBaseline = probe.shell
        let cardBaseline = probe.card
        for step in 1...30 {
            let seen = probe.card
            bridge.follow(CGFloat(step) * 8)
            flushUntil(probe: probe, changesFrom: seen)
        }
        XCTAssertGreaterThanOrEqual(probe.card - cardBaseline, 20, "card \(probe.card) shell \(probe.shell)")
        XCTAssertLessThanOrEqual(probe.shell - shellBaseline, 2, "card \(probe.card) shell \(probe.shell)")
    }

    private var displacedKey: UIWindow?
    private var layoutView: UIView?

    private func show<Content: View>(_ root: Content) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        displacedKey = previous
        layoutView = controller.view
        return window
    }

    private func hide(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
        displacedKey?.makeKeyAndVisible()
        displacedKey = nil
        layoutView = nil
    }

    /// Nested `RunLoop.run` returns without committing SwiftUI, so a progress
    /// write looked like it never reached the card. `wait` runs the main queue
    /// the update is scheduled on. The deadline is not the pass condition.
    private func flushUntil(probe: TransitionEvaluationProbe, changesFrom seen: Int) {
        let done = expectation(description: "card progress committed")
        let start = Date()
        func tick() {
            CATransaction.flush()
            layoutView?.layoutIfNeeded()
            if probe.card != seen || Date().timeIntervalSince(start) >= 0.2 {
                done.fulfill()
                return
            }
            DispatchQueue.main.async(execute: tick)
        }
        DispatchQueue.main.async(execute: tick)
        wait(for: [done], timeout: 1)
    }
}

private final class TransitionEvaluationProbe {
    var shell = 0
    var card = 0
    var didReady = false
}

private struct PlayerShellProbe: View {
    var probe: TransitionEvaluationProbe
    var bridge: PlayerGestureBridge
    var ready: () -> Void

    var body: some View {
        let _ = probe.shell += 1
        PlayerMotionHost(presented: true, generation: 1,
                         miniFrame: CGRect(x: 0, y: 700, width: 320, height: 56),
                         expandedFrame: CGRect(x: 0, y: 0, width: 390, height: 844),
                         reduceMotion: false, animation: .linear(duration: 0.3),
                         canReopen: false, gestures: bridge, onReopen: {},
                         onMounted: { ready(); return nil }, onComplete: { _ in },
                         onEvaluate: { probe.card += 1 }) {
            Color.black
        } expanded: {
            Color.red
        } collapsed: {
            Color.blue
        }
    }
}

@MainActor
private final class ReturnAppearanceState: ObservableObject {
    @Published var mounted = false
    @Published var detailPath: [DetailZoomRoute] = []
    @Published var progress: CGFloat = 0
}

private final class AppearanceProbeView: UIView {
    var scheme: ColorScheme?
}

private struct AppearanceProbe: UIViewRepresentable {
    var view: AppearanceProbeView
    @Environment(\.colorScheme) private var scheme
    func makeUIView(context: Context) -> AppearanceProbeView { view }
    func updateUIView(_ uiView: AppearanceProbeView, context: Context) {
        uiView.scheme = scheme
        uiView.backgroundColor = .systemBackground
    }
}

/// Uses the real destination and card types, with the same local dark scope as
/// LibraryView. It isolates preference propagation, not native tab-bar animation.
private struct ReturnAppearanceHarness: View {
    @Namespace private var zoom
    @ObservedObject var state: ReturnAppearanceState
    var library: LibraryStore
    var player: PlayerStore
    var kind: CollectionPage.Kind?
    var baseProbe: AppearanceProbeView
    var contentProbe: AppearanceProbeView

    var body: some View {
        GeometryReader { geometry in
            let expanded = CGRect(origin: .zero, size: geometry.size)
            let mini = CGRect(x: 12, y: geometry.size.height - 80,
                              width: geometry.size.width - 24, height: 56)
            Color(uiColor: .systemBackground)
                .overlay(alignment: .topLeading) {
                    AppearanceProbe(view: baseProbe).frame(width: 8, height: 8)
                }
                .overlay(alignment: .topLeading) {
                    if let kind {
                        NavigationStack(path: $state.detailPath) {
                            Color(uiColor: .systemBackground)
                                .modifier(DetailZoomSource(
                                    id: DetailZoomRoute(route: .album("appearance"), grid: .albumIndex),
                                    namespace: zoom))
                                .navigationDestination(for: DetailZoomRoute.self) { detail in
                                    CollectionPage(library: library, player: player, title: "Detail",
                                        tracks: [], kind: kind, onOpen: { _ in },
                                        onAddToPlaylist: { _ in }, onDelete: { _ in }, onLyrics: { _ in })
                                        .modifier(DetailZoomDestination(id: detail, namespace: zoom))
                                        .overlay { AppearanceProbe(view: contentProbe).frame(width: 8, height: 8) }
                                }
                        }
                    }
                    if state.mounted {
                        if kind == nil {
                            PlayerCard(progress: state.progress, miniFrame: mini,
                                expandedFrame: expanded, reduceMotion: false,
                                canReopen: false, onReopen: {}) {
                                    NowPlayingBackground(library: library, player: player)
                                } expanded: {
                                    NowPlayingView(library: library, player: player)
                                        .overlay { AppearanceProbe(view: contentProbe).frame(width: 8, height: 8) }
                                        .environment(\.colorScheme, .dark)
                                } collapsed: {
                                    MiniPlayer(library: library, player: player, compact: false) {}
                                }
                        }
                    }
                }
        }
    }
}

private struct NativeCollectionAppearanceHarness: View {
    var page: CollectionPage
    var detail: DetailZoomRoute
    @State private var path: [DetailZoomRoute]
    @Namespace private var zoom

    init(page: CollectionPage, detail: DetailZoomRoute, pushed: Bool) {
        self.page = page
        self.detail = detail
        _path = State(initialValue: pushed ? [detail] : [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            Color(uiColor: .systemBackground)
                .modifier(DetailZoomSource(id: detail, namespace: zoom))
                .navigationDestination(for: DetailZoomRoute.self) { detail in
                    page.modifier(DetailZoomDestination(id: detail, namespace: zoom))
                }
        }
    }
}
