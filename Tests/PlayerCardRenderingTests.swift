import XCTest
import SwiftUI
import UIKit
@testable import LosslessPlayer

@MainActor
final class PlayerCardRenderingTests: XCTestCase {
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
                Color.green.frame(height: geometry.size.height * 0.75)
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

    func testDetailTintTracksInheritedAppearance() {
        for sampled in ArtworkColors.fallback + [UIColor.blue, .red, .black] {
            let light = CollectionArtworkColor.resolve(sampled, scheme: .light)
            let dark = CollectionArtworkColor.resolve(sampled, scheme: .dark)
            var brightness: CGFloat = 0
            light.getHue(nil, saturation: nil, brightness: &brightness, alpha: nil)
            XCTAssertGreaterThanOrEqual(brightness, 0.93)
            XCTAssertEqual(dark, sampled)
        }
    }

    func testCollectionOverlayDoesNotChangeLightWindowAppearance() async throws {
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
        let size = window.bounds.size
        let expanded = CGRect(origin: .zero, size: size)
        let source = DetailCardSource(route: .albums,
            frame: CGRect(x: 60, y: 180, width: 140, height: 140), artwork: AnyView(Color.green))
        let samples: [CGFloat] = [0, 0.2, 0.5, 0.8, 1]
        for progress in samples + samples.reversed() {
            let host = UIHostingController(rootView:
                Color(uiColor: .systemBackground)
                    .overlay(alignment: .topLeading) {
                        DetailZoomCard(progress: progress, source: source, expanded: expanded,
                            headerFrame: source.frame, transitioning: true, reduceMotion: false,
                            detail: NavigationStack { page })
                    })
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            // Let SwiftUI propagate presentation preferences through UIKit.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(host.traitCollection.userInterfaceStyle, .light,
                           "Collection preference escaped its overlay at progress \(progress)")
            XCTAssertEqual(window.overrideUserInterfaceStyle, .light)
        }
    }

    func testDetailZoomKeepsUnderlyingAppearanceAtEverySampleInBothDirections() throws {
        let source = DetailCardSource(route: .albums,
            frame: CGRect(x: 60, y: 180, width: 140, height: 140), artwork: AnyView(Color.green))
        let expanded = CGRect(x: 0, y: 0, width: 360, height: 720)
        let samples: [CGFloat] = [0, 0.15, 0.35, 0.65, 0.85]
        for scheme in [ColorScheme.light, .dark] {
            for progress in samples + samples.reversed() {
                let renderer = ImageRenderer(content:
                    Color(uiColor: .systemBackground).frame(width: 360, height: 720)
                        .overlay(alignment: .topLeading) {
                            DetailZoomCard(progress: progress, source: source, expanded: expanded,
                                headerFrame: CGRect(x: 55, y: 60, width: 250, height: 250),
                                transitioning: true, reduceMotion: false,
                                detail: Color(uiColor: CollectionArtworkColor.resolve(.blue, scheme: scheme)))
                        }
                        .environment(\.colorScheme, scheme))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                let pixels = try rgbaPixels(in: image)
                // x=2,y=2 stays outside the growing card at every sample.
                // Only the intentional 12% dimming is allowed, never a scheme flip.
                let offset = (2 * image.width + 2) * 4
                for channel in 0..<3 {
                    if scheme == .light {
                        XCTAssertGreaterThan(pixels[offset + channel], 220)
                    } else {
                        XCTAssertLessThan(pixels[offset + channel], 8)
                    }
                }
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
}
