import XCTest
import SwiftUI
import UIKit
@testable import LosslessPlayer

@MainActor
final class PlayerCardRenderingTests: XCTestCase {
    func testArtworkFillsTopStripAndSharesCardClipAtDragAndSpringProgress() throws {
        let mini = CGRect(x: 12, y: 600, width: 336, height: 56)
        let expanded = CGRect(x: 0, y: 0, width: 360, height: 720)
        let texture = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        for scheme in [ColorScheme.light, .dark] {
            // Includes invisible expanded controls, intermediate drag frames,
            // and spring overshoot. No animation timer drives these samples.
            for progress in [CGFloat(0.25), 0.3, 0.5, 0.8, 0.95, 1, 1.05] {
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
                    Color.blue
                        .frame(width: 360, height: 720)
                        .overlay(alignment: .topLeading) { card }
                        .environment(\.colorScheme, scheme)
                )
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                // Normalize pixel layout instead of depending on CGImage's
                // byte order or premultiplied-alpha representation.
                var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
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
}
