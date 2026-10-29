import SwiftUI

/// Pure mapping shared by the finger, spring and rendered card. Progress is
/// zero in the accessory slot and one at full screen.
enum PlayerCardMetrics {
    static func progress(for translation: CGFloat, distance: CGFloat) -> CGFloat {
        guard distance > 0 else { return 1 }
        return min(1, max(0, 1 - max(0, translation) / distance))
    }

    static func frame(progress: CGFloat, mini: CGRect, expanded: CGRect) -> CGRect {
        let p = min(1, max(0, progress))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        return CGRect(x: mix(mini.minX, expanded.minX), y: mix(mini.minY, expanded.minY),
                      width: mix(mini.width, expanded.width), height: mix(mini.height, expanded.height))
    }

    static func topRadius(_ progress: CGFloat) -> CGFloat {
        18 + 14 * min(1, max(0, progress))
    }

    // Serial fades keep the two layout covers mutually exclusive, including
    // at slow-drag and spring frames. There is no independent landing timer.
    static func miniOpacity(_ progress: CGFloat) -> Double {
        Double(min(1, max(0, (0.25 - progress) / 0.25)))
    }

    static func expandedOpacity(_ progress: CGFloat) -> Double {
        Double(min(1, max(0, (progress - 0.3) / 0.35)))
    }
}

/// Animatable evaluates *all* derived geometry and opacity at the presented
/// spring value, rather than starting separate implicit layout/fade animations.
struct PlayerCard<Background: View, Expanded: View, Collapsed: View>: View, Animatable {
    var progress: CGFloat
    var miniFrame: CGRect
    var expandedFrame: CGRect
    var reduceMotion: Bool
    var canReopen: Bool
    var onReopen: () -> Void
    var background: Background
    var expanded: Expanded
    var collapsed: Collapsed

    init(progress: CGFloat, miniFrame: CGRect, expandedFrame: CGRect, reduceMotion: Bool,
         canReopen: Bool, onReopen: @escaping () -> Void,
         @ViewBuilder background: () -> Background,
         @ViewBuilder expanded: () -> Expanded, @ViewBuilder collapsed: () -> Collapsed) {
        self.progress = progress
        self.miniFrame = miniFrame
        self.expandedFrame = expandedFrame
        self.reduceMotion = reduceMotion
        self.canReopen = canReopen
        self.onReopen = onReopen
        self.background = background()
        self.expanded = expanded()
        self.collapsed = collapsed()
    }

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = min(1, max(0, progress))
        let frame = PlayerCardMetrics.frame(progress: p, mini: miniFrame, expanded: expandedFrame)
        // Reduce Motion keeps both layouts stationary at their resting frames;
        // only the same progress-driven fades run. No drag scrubbing or travel.
        let bounds = reduceMotion && p > 0 ? expandedFrame : frame
        let miniOrigin = reduceMotion && p > 0
            ? CGSize(width: miniFrame.minX - bounds.minX, height: miniFrame.minY - bounds.minY)
            : .zero
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.regularMaterial)
                .frame(width: reduceMotion ? miniFrame.width : bounds.width,
                       height: reduceMotion ? miniFrame.height : bounds.height)
                .offset(miniOrigin)
            // Size the surface before attaching artwork so scaled-to-fill
            // images cannot participate in the card's layout negotiation.
            // Safe-area padding and control fades apply only to content.
            Color.clear
                .frame(width: bounds.width, height: bounds.height)
                .background { background }
                .opacity(reduceMotion ? PlayerCardMetrics.expandedOpacity(p)
                         : 1 - PlayerCardMetrics.miniOpacity(p))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            expanded
                .frame(width: expandedFrame.width, height: expandedFrame.height)
                .opacity(PlayerCardMetrics.expandedOpacity(p))
            collapsed
                .frame(width: miniFrame.width, height: miniFrame.height)
                .opacity(PlayerCardMetrics.miniOpacity(p))
                .offset(miniOrigin)
        }
        // The expanded layout keeps its resting size inside this one card:
        // its cover never scales or drifts diagonally toward the mini slot.
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: PlayerCardMetrics.topRadius(p),
            bottomLeadingRadius: 18 * (1 - p),
            bottomTrailingRadius: 18 * (1 - p),
            topTrailingRadius: PlayerCardMetrics.topRadius(p), style: .continuous))
        .contentShape(Rectangle())
        .overlay {
            // Created only after a close begins: a tap on the expanded close
            // button cannot bubble into a parent gesture and reopen it.
            if canReopen {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onReopen)
                    .accessibilityLabel("展开播放器")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .offset(x: bounds.minX, y: bounds.minY)
    }
}

struct PlayerMiniSlot: Equatable {
    var frame: CGRect = .zero
    var compact = false
}

/// The system still owns accessory placement/minimization and tab layout.
/// This has no artwork or controls: there is only one visible player card.
struct PlayerMiniSlotView: View {
    var onMeasure: (PlayerMiniSlot) -> Void

    var body: some View {
        if #available(iOS 26, *) {
            GlassPlayerMiniSlot(onMeasure: onMeasure)
        } else {
            PlayerMiniSlotMeasure(compact: false, onMeasure: onMeasure)
        }
    }
}

@available(iOS 26, *)
private struct GlassPlayerMiniSlot: View {
    var onMeasure: (PlayerMiniSlot) -> Void
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    var body: some View { PlayerMiniSlotMeasure(compact: placement == .inline, onMeasure: onMeasure) }
}

private struct PlayerMiniSlotMeasure: View {
    var compact: Bool
    var onMeasure: (PlayerMiniSlot) -> Void
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 56

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 36 : max(56, rowHeight))
            .background {
                GeometryReader { geometry in
                    let slot = PlayerMiniSlot(frame: geometry.frame(in: .global), compact: compact)
                    Color.clear
                        .onAppear { report(slot) }
                        .onChange(of: slot) { _, next in report(next) }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func report(_ slot: PlayerMiniSlot) {
        // The native accessory lays out in a separate host. Do not traverse
        // its preferences or invalidate the parent during that layout pass.
        DispatchQueue.main.async { onMeasure(slot) }
    }
}
