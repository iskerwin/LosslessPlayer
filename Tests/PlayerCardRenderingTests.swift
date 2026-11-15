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

/// Uses the real destination types, with the same local dark scope as
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
