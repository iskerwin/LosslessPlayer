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
    var measure: ((CGRect, URL?) -> Void)?
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

/// Latest cover frame. A class so scrolling can update it without redrawing the cell.
final class DetailCardSlot {
    var frame: CGRect = .zero
}

/// Test hook. Production links keep the empty default.
final class DetailCardLinkProbe {
    var evaluate: () -> Void = {}
    var ready: (DetailCardSlot) -> Void = { _ in }
    var attached: DetailCardSlot?
}

/// Only grid artwork opts in. The button measures its square artwork slot;
/// source text keeps its normal layout while the grid stays stationary.
struct DetailCardLink<Artwork: View, Label: View>: View {
    var route: LibraryRoute
    var fallback: () -> Void
    var probe: DetailCardLinkProbe
    var artwork: () -> Artwork
    var label: (AnyView) -> Label
    @Environment(\.detailCardContext) private var context
    /// Not observed: writing `frame` during scroll must not rebuild the cell.
    @State private var slot = DetailCardSlot()

    init(route: LibraryRoute, fallback: @escaping () -> Void,
         probe: DetailCardLinkProbe = DetailCardLinkProbe(),
         @ViewBuilder artwork: @escaping () -> Artwork,
         @ViewBuilder label: @escaping (AnyView) -> Label) {
        self.route = route
        self.fallback = fallback
        self.probe = probe
        self.artwork = artwork
        self.label = label
    }

    var body: some View {
        let slot = slot
        let _ = probe.evaluate()
        let _ = probe.ready(slot)
        Button {
            let frame = slot.frame
            if let open = context.open, frame.width > 0, frame.height > 0 {
                open(DetailCardSource(route: route, frame: frame, artwork: AnyView(artwork())))
            } else {
                fallback()
            }
        } label: {
            label(AnyView(artwork()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { slot.frame = $0 }
                .opacity(context.active == route ? 0 : 1)))
        }
    }
}

struct DetailHeaderArtwork: ViewModifier {
    var backgroundURL: URL? = nil
    @Environment(\.detailCardHeader) private var header
    func body(content: Content) -> some View {
        content
            .opacity(header.hidden ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { header.measure?($0, backgroundURL) }
    }
}

enum DetailCardMetrics {
    static func frame(_ progress: CGFloat, source: CGRect, destination: CGRect) -> CGRect {
        let p = min(1, max(0, progress))
        if p == 0 { return source }
        if p == 1 { return destination }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        return CGRect(x: mix(source.minX, destination.minX), y: mix(source.minY, destination.minY),
                      width: mix(source.width, destination.width), height: mix(source.height, destination.height))
    }
    static func radius(_ progress: CGFloat) -> CGFloat {
        // The source has 12 pt corners; expansion only flattens them.
        let p = min(1, max(0, progress))
        return 12 * (1 - p)
    }
    static func contentOpacity(_ progress: CGFloat) -> Double {
        // The moving clip reveals an opaque page, never a dissolve over the grid.
        1
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
    var backgroundURL: URL? = nil

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
                ArtworkBackground(url: backgroundURL, followsAppearance: true)
                    .frame(width: expanded.width, height: expanded.height)
                    .offset(x: expanded.minX - card.minX, y: expanded.minY - card.minY)
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
            .offset(x: card.minX, y: card.minY)
        }
        // This animatable view already samples the spring. In particular, the
        // cover inserted on close must not start a second implicit frame/opacity
        // animation from its header size while the outer card is shrinking.
        .transaction { if transitioning { $0.animation = nil } }
    }
}

/// Header measure and close. The card installs these; the shell never sees
/// the progress those callbacks animate.
final class DetailCardActions {
    var measure: (CGRect, URL?) -> Void = { _, _ in }
    var close: () -> Void = {}
    /// Latest header, kept off view state so scrolling does not rebuild the card.
    var latestHeader = CGRect.zero
}

/// Lets the playlist tab run the same close as the card's back button.
/// Removing the card from the shell skips the travel back to the cover.
final class DetailCardDismiss {
    var close: () -> Void = {}
}

/// Writes detail progress from a test without a display link. Production
/// leaves it nil. The shell must not observe the writes.
final class DetailProgressDrive {
    var write: (CGFloat) -> Void = { _ in }
    func set(_ value: CGFloat) { write(value) }
}

/// Owns detail open and close progress. Album grids stay in the shell and
/// are not rebuilt on each frame of this spring.
struct DetailMotionHost<Detail: View>: View {
    var source: DetailCardSource
    var expanded: CGRect
    var reduceMotion: Bool
    var spaceOrigin: CGPoint
    var onWillClose: () -> Void
    var onClosed: () -> Void
    var dismiss: DetailCardDismiss? = nil
    var progressDrive: DetailProgressDrive? = nil
    var onReady: () -> Void = {}
    var onEvaluate: () -> Void = {}
    var detail: Detail
    @State private var progress: CGFloat = 0
    @State private var headerFrame: CGRect = .zero
    @State private var backgroundURL: URL?
    @State private var transitioning = true
    @State private var closing = false
    @State private var generation = 0
    @State private var actions = DetailCardActions()

    init(source: DetailCardSource, expanded: CGRect, reduceMotion: Bool, spaceOrigin: CGPoint,
         onWillClose: @escaping () -> Void, onClosed: @escaping () -> Void,
         dismiss: DetailCardDismiss? = nil,
         progressDrive: DetailProgressDrive? = nil, onReady: @escaping () -> Void = {},
         onEvaluate: @escaping () -> Void = {},
         @ViewBuilder detail: () -> Detail) {
        self.source = source
        self.expanded = expanded
        self.reduceMotion = reduceMotion
        self.spaceOrigin = spaceOrigin
        self.onWillClose = onWillClose
        self.onClosed = onClosed
        self.dismiss = dismiss
        self.progressDrive = progressDrive
        self.onReady = onReady
        self.onEvaluate = onEvaluate
        self.detail = detail()
    }

    var body: some View {
        let _ = onEvaluate()
        let _ = bind()
        DetailZoomCard(progress: progress, source: source, expanded: expanded,
                       headerFrame: headerFrame, transitioning: transitioning,
                       reduceMotion: reduceMotion,
                       detail: DetailHeaderScope(hidden: transitioning && !reduceMotion,
                                                 actions: actions, content: detail),
                       backgroundURL: backgroundURL)
            .allowsHitTesting(progress == 1 && !transitioning)
            .accessibilityIdentifier("detail-card")
            .onAppear(perform: onReady)
    }

    private func bind() {
        let origin = spaceOrigin
        let headerFrame = $headerFrame
        let backgroundURL = $backgroundURL
        let progress = $progress
        let transitioning = $transitioning
        let closing = $closing
        let generation = $generation
        let reduceMotion = reduceMotion
        let onWillClose = onWillClose
        let onClosed = onClosed
        let card = actions
        card.measure = { frame, url in
            guard frame.width > 0, frame.height > 0, !closing.wrappedValue else { return }
            let local = frame.offsetBy(dx: -origin.x, dy: -origin.y)
            card.latestHeader = local
            // Freeze the target once travel starts. The moving card would
            // otherwise report a new header frame on every spring tick.
            guard progress.wrappedValue == 0, transitioning.wrappedValue else { return }
            headerFrame.wrappedValue = local
            backgroundURL.wrappedValue = url
            let token = generation.wrappedValue
            CardProgressTravel.animate(progress, to: 1, reduceMotion: reduceMotion) {
                guard token == generation.wrappedValue, !closing.wrappedValue else { return }
                transitioning.wrappedValue = false
            }
        }
        card.close = {
            guard !closing.wrappedValue else { return }
            closing.wrappedValue = true
            transitioning.wrappedValue = true
            generation.wrappedValue += 1
            let token = generation.wrappedValue
            if card.latestHeader.width > 0, card.latestHeader.height > 0 {
                headerFrame.wrappedValue = card.latestHeader
            }
            onWillClose()
            CardProgressTravel.animate(progress, to: 0, reduceMotion: reduceMotion) {
                guard token == generation.wrappedValue else { return }
                onClosed()
            }
        }
        dismiss?.close = card.close
        if let progressDrive {
            progressDrive.write = { value in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { progress.wrappedValue = value }
            }
        }
    }
}

private enum CardProgressTravel {
    static func animate(_ progress: Binding<CGFloat>, to target: CGFloat, reduceMotion: Bool,
                        completion: @escaping () -> Void) {
        let animation: Animation = reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.48, dampingFraction: 1)
        if progress.wrappedValue == target {
            DispatchQueue.main.async(execute: completion)
            return
        }
        withAnimation(animation, completionCriteria: .removed) {
            progress.wrappedValue = target
        } completion: {
            completion()
        }
    }
}

/// Applies the header environment. Its inputs stay still while only the
/// card's progress changes, so the detail page is not rebuilt per frame.
private struct DetailHeaderScope<Content: View>: View {
    var hidden: Bool
    var actions: DetailCardActions
    var content: Content

    var body: some View {
        content.environment(\.detailCardHeader, DetailCardHeader(
            hidden: hidden,
            measure: { actions.measure($0, $1) },
            close: { actions.close() }
        ))
    }
}

struct DetailCardBackButton: View {
    @Environment(\.detailCardHeader) private var header

    var body: some View {
        Button(action: { header.close?() }) {
            Image(systemName: "chevron.left")
        }
        .accessibilityLabel("返回")
        .accessibilityIdentifier("detail-card-back")
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
