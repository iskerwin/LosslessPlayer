import ImageIO
import SwiftUI
import UIKit

/// Display-sized artwork cache.
///
/// Stored thumbnails are up to 700px JPEGs. Decoding one of those on the main
/// thread costs about 2MB of RGBA (700×700×4) and only ~24 of them fit in a
/// 48MB cache, so scrolling a library thrashed: every newly visible row
/// decoded a full bitmap and evicted another. Rows now ask for a 240px tier
/// (~0.2MB) and grids for 540px. ImageIO downsamples while decoding, the
/// decode runs off the main thread, and a cache hit (or a larger tier that
/// is already decoded) is drawn on the first frame so lists do not flash.
final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    private let images = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private let decodeQueue = DispatchQueue(label: "lossless.artwork-decode", qos: .userInitiated, attributes: .concurrent)
    private var bestPixel: [String: CGFloat] = [:]
    private var inflight: [String: LoadBox] = [:]
    /// Bumped by `removeAll` so an in-flight decode cannot refill the cache
    /// after a scan drops every thumbnail.
    private var generation = 0

    init() {
        images.countLimit = 400
        images.totalCostLimit = 48 * 1024 * 1024
    }

    /// Pixel bucket for a view of `points` at `scale`. Shared buckets keep
    /// a song row, the mini player, and a menu preview on one decode.
    static func displayTier(points: CGFloat, scale: CGFloat) -> CGFloat {
        let pixels = max(1, points) * max(scale, 1)
        if pixels <= 280 { return 240 }
        if pixels <= 620 { return 540 }
        return 700
    }

    func cachedImage(at url: URL, maxPixel: CGFloat) -> UIImage? {
        images.object(forKey: Self.cacheKey(path: url.path, pixel: maxPixel) as NSString)
    }

    /// Exact hit, otherwise any already-decoded tier of the same file so a
    /// larger view can show the row thumbnail immediately while the sharp
    /// tier loads.
    func bestCachedImage(at url: URL, maxPixel: CGFloat) -> UIImage? {
        if let exact = cachedImage(at: url, maxPixel: maxPixel) { return exact }
        let path = url.path
        for pixel in [CGFloat(700), 540, 240] where pixel != maxPixel {
            if let image = images.object(forKey: Self.cacheKey(path: path, pixel: pixel) as NSString) {
                return image
            }
        }
        lock.lock()
        let known = bestPixel[path]
        lock.unlock()
        guard let known, known != maxPixel else { return nil }
        return images.object(forKey: Self.cacheKey(path: path, pixel: known) as NSString)
    }

    /// Synchronous decode for callers already off the main thread (palette,
    /// tests). UI paths should use `load` so a miss never blocks scrolling.
    func image(at url: URL, maxPixel: CGFloat = 700) -> UIImage? {
        let pixel = max(1, maxPixel.rounded())
        if let cached = cachedImage(at: url, maxPixel: pixel) { return cached }
        let token = currentGeneration
        guard let image = Self.decode(url: url, maxPixel: pixel) else { return nil }
        guard token == currentGeneration else { return image }
        store(image, path: url.path, pixel: pixel)
        return image
    }

    func load(at url: URL, maxPixel: CGFloat) async -> UIImage? {
        let pixel = max(1, maxPixel.rounded())
        let key = Self.cacheKey(path: url.path, pixel: pixel)
        if let cached = images.object(forKey: key as NSString) { return cached }
        let token = currentGeneration
        let (box, isOwner): (LoadBox, Bool) = {
            lock.lock()
            defer { lock.unlock() }
            if let existing = inflight[key] { return (existing, false) }
            let created = LoadBox(Task<UIImage?, Never> {
                await withCheckedContinuation { continuation in
                    self.decodeQueue.async {
                        continuation.resume(returning: Self.decode(url: url, maxPixel: pixel))
                    }
                }
            })
            inflight[key] = created
            return (created, true)
        }()
        let image = await box.task.value
        if isOwner {
            let live = token == currentGeneration
            if live, let image { store(image, path: url.path, pixel: pixel) }
            lock.lock()
            if inflight[key] === box { inflight[key] = nil }
            lock.unlock()
            return live ? image : nil
        }
        return token == currentGeneration ? image : nil
    }

    func removeAll() {
        images.removeAllObjects()
        lock.lock()
        generation += 1
        bestPixel.removeAll()
        inflight.removeAll()
        lock.unlock()
    }

    private var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func store(_ image: UIImage, path: String, pixel: CGFloat) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        images.setObject(image, forKey: Self.cacheKey(path: path, pixel: pixel) as NSString, cost: cost)
        lock.lock()
        if (bestPixel[path] ?? 0) < pixel { bestPixel[path] = pixel }
        lock.unlock()
    }

    private static func cacheKey(path: String, pixel: CGFloat) -> String {
        path + "#" + String(Int(pixel.rounded()))
    }

    /// ImageIO thumbnail options skip the full-size intermediate bitmap.
    private final class LoadBox {
        let task: Task<UIImage?, Never>
        init(_ task: Task<UIImage?, Never>) { self.task = task }
    }

    private static func decode(url: URL, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let pixel = max(1, maxPixel.rounded())
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixel,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }
}

struct FileArtwork: View {
    var url: URL?
    /// Layout size in points. Nil sizes a flexible square (album grids).
    var pointSize: CGFloat?
    var placeholder: ArtworkView.Placeholder = .accent
    /// Playlist covers clip themselves; skip the inner corner when the parent does.
    var shaped = true
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?

    private var tier: CGFloat {
        ArtworkCache.displayTier(points: pointSize ?? 180, scale: displayScale)
    }

    private var displayed: UIImage? {
        if let image { return image }
        guard let url else { return nil }
        return ArtworkCache.shared.bestCachedImage(at: url, maxPixel: tier)
    }

    var body: some View {
        ZStack {
            placeholderView.opacity(displayed == nil ? 1 : 0)
            if let displayed {
                Image(uiImage: displayed)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: displayed == nil)
        .frame(width: pointSize, height: pointSize)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: shaped ? artworkCorner : 0, style: .continuous))
        .accessibilityHidden(true)
        .task(id: taskID) { await load() }
    }

    private var taskID: String {
        "\(url?.path ?? "")#\(Int(tier))"
    }

    private func load() async {
        guard let url else { return }
        if ArtworkCache.shared.cachedImage(at: url, maxPixel: tier) != nil { return }
        let loaded = await ArtworkCache.shared.load(at: url, maxPixel: tier)
        guard !Task.isCancelled else { return }
        image = loaded
    }

    @ViewBuilder private var placeholderView: some View {
        if placeholder == .neutral {
            ZStack {
                Color(white: 0.16)
                Image(systemName: "music.note").resizable().scaledToFit().padding(30).foregroundStyle(.white.opacity(0.85))
            }
        } else {
            ZStack {
                LinearGradient(colors: [MusicTheme.accent.opacity(0.85), .pink.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").resizable().scaledToFit().padding(30).foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private var artworkCorner: CGFloat {
        let side = pointSize ?? 150
        if side <= 64 { return 6 }
        if side < 120 { return 8 }
        return 12
    }
}

struct ArtworkView: View {
    enum Placeholder { case accent, neutral }
    let track: Track?
    let root: URL
    var size: CGFloat?
    var placeholder: Placeholder = .accent

    var body: some View {
        FileArtwork(
            url: track?.artworkFilename.map { root.appendingPathComponent($0) },
            pointSize: size,
            placeholder: placeholder
        )
    }
}
