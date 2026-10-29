import SwiftUI

/// Screen-space measurements are captured at the tapped artwork, never inferred
/// from grid columns, scroll offsets, device size, or a different cell.
struct DetailCardSource {
    var route: LibraryRoute
    var frame: CGRect
    var artwork: AnyView
}

struct DetailCardContext {
    var active: LibraryRoute?
    var open: ((DetailCardSource) -> Void)?
}

private struct DetailCardContextKey: EnvironmentKey {
    static let defaultValue = DetailCardContext()
}
private struct DetailCardHeaderKey: EnvironmentKey {
    static let defaultValue = DetailCardHeader()
}
struct DetailCardHeader {
    var hidden = false
    var measure: ((CGRect) -> Void)?
    var close: (() -> Void)?
}
extension EnvironmentValues {
    var detailCardContext: DetailCardContext {
        get { self[DetailCardContextKey.self] }
        set { self[DetailCardContextKey.self] = newValue }
    }
    var detailCardHeader: DetailCardHeader {
        get { self[DetailCardHeaderKey.self] }
        set { self[DetailCardHeaderKey.self] = newValue }
    }
}

/// Only grid artwork opts in. The button measures its square artwork slot;
/// source text keeps its normal layout while the grid stays stationary.
struct DetailCardLink<Artwork: View, Label: View>: View {
    var route: LibraryRoute
    var fallback: () -> Void
    @ViewBuilder var artwork: () -> Artwork
    @ViewBuilder var label: (AnyView) -> Label
    @Environment(\.detailCardContext) private var context
    @State private var slot: CGRect = .zero

    var body: some View {
        Button {
            if let open = context.open, slot.width > 0, slot.height > 0 {
                open(DetailCardSource(route: route, frame: slot, artwork: AnyView(artwork())))
            } else {
                fallback()
            }
        } label: {
            label(AnyView(artwork()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { slot = $0 }
                .opacity(context.active == route ? 0 : 1)))
        }
    }
}

struct DetailHeaderArtwork: ViewModifier {
    @Environment(\.detailCardHeader) private var header
    func body(content: Content) -> some View {
        content
            .opacity(header.hidden ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { header.measure?($0) }
    }
}

enum DetailCardMetrics {
    static func frame(_ progress: CGFloat, source: CGRect, destination: CGRect) -> CGRect {
        let p = min(1, max(0, progress))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        return CGRect(x: mix(source.minX, destination.minX), y: mix(source.minY, destination.minY),
                      width: mix(source.width, destination.width), height: mix(source.height, destination.height))
    }
    static func radius(_ progress: CGFloat) -> CGFloat {
        // Keep a readable outside corner until the last part of expansion.
        let p = min(1, max(0, progress))
        return 12 * (1 - p) + 24 * sin(.pi * p)
    }
    static func contentOpacity(_ progress: CGFloat) -> Double {
        Double(min(1, max(0, (progress - 0.15) / 0.85)))
    }
}

/// One animatable scalar evaluates geometry, both corners and opacity at every
/// displayed frame. Closing simply animates that scalar from one back to zero.
struct DetailZoomCard<Detail: View>: View, Animatable {
    var progress: CGFloat
    var source: DetailCardSource
    var expanded: CGRect
    var headerFrame: CGRect
    var transitioning: Bool
    var reduceMotion: Bool
    var detail: Detail

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = min(1, max(0, progress))
        let card = reduceMotion ? expanded : DetailCardMetrics.frame(p, source: source.frame, destination: expanded)
        let cover = DetailCardMetrics.frame(p, source: source.frame, destination: headerFrame)
        ZStack(alignment: .topLeading) {
            // Dimming shares this very same presented progress with the card.
            Color.black.opacity(0.12 * Double(p))
                .frame(width: expanded.width, height: expanded.height)
                .position(x: expanded.midX, y: expanded.midY)
            ZStack(alignment: .topLeading) {
                Color(uiColor: .systemBackground)
                detail
                    .frame(width: expanded.width, height: expanded.height)
                    // Lay out the destination at its resting screen position.
                    // Its measured header must not feed the moving card's
                    // offset back into the destination geometry each frame.
                    .offset(x: expanded.minX - card.minX, y: expanded.minY - card.minY)
                    .opacity(reduceMotion ? 1 : DetailCardMetrics.contentOpacity(p))
                if transitioning && !reduceMotion {
                    // The grid and detail artwork are hidden during travel. This
                    // is the only visible cover, inside the growing card.
                    source.artwork
                        .frame(width: cover.width, height: cover.height)
                        .offset(x: cover.minX - card.minX, y: cover.minY - card.minY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: card.width, height: card.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: reduceMotion ? 0 : DetailCardMetrics.radius(p), style: .continuous))
            .opacity(reduceMotion ? Double(p) : 1)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detail-card-surface")
            .offset(x: card.minX, y: card.minY)
        }
    }
}

struct DetailGridModifier: ViewModifier {
    var context: DetailCardContext
    var covered: Bool
    func body(content: Content) -> some View {
        content
            .environment(\.detailCardContext, context)
            .allowsHitTesting(!covered)
            .accessibilityHidden(covered)
    }
}
