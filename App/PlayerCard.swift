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

    // Keep the expanded sheet opaque until the final 6% of travel. Serial
    // fades hand over to mini only at landing, without overlapping covers
    // or an independent timer during slow drags, reversal or spring frames.
    static func miniOpacity(_ progress: CGFloat) -> Double {
        Double(min(1, max(0, (0.03 - progress) / 0.03)))
    }

    static func expandedOpacity(_ progress: CGFloat) -> Double {
        Double(min(1, max(0, (progress - 0.03) / 0.03)))
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
            // Keep the backdrop at its full-screen resting size. Resizing it
            // to the shrinking card compresses the dark bottom gradient upward
            // while the expanded controls still use full-screen coordinates.
            // Crop one continuous texture through the card until mini takes over.
            background
                .frame(width: expandedFrame.width, height: expandedFrame.height)
                .clipped()
                .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
                .clipped()
                .opacity(reduceMotion ? PlayerCardMetrics.expandedOpacity(p)
                         : 1 - PlayerCardMetrics.miniOpacity(p))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            expanded
                .frame(width: expandedFrame.width, height: expandedFrame.height)
                .opacity(PlayerCardMetrics.expandedOpacity(p))
            collapsed
                .frame(width: miniFrame.width, height: miniFrame.height)
                // The accessory surface remains visible when its CONTENT is
                // hidden during travel. A second glass here nests two outlines
                // at landing (also over the legacy inset's material).
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

/// Glass for the pre-iOS 26 inset. The resting iOS 26
/// accessory intentionally relies on the system surface (see GlassPlayerMiniSlot).
/// Applying glass to the sized content keeps artwork, text and controls above
/// the frosted backdrop; no translucent color or opaque material is underneath.
struct PlayerMiniGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(iOS 26, *) {
            GlassEffectContainer {
                content.glassEffect(.regular, in: shape)
            }
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

struct PlayerMiniSlot: Equatable {
    var frame: CGRect = .zero
    var compact = false
}

/// Native accessory ownership keeps placement and content in the same animation.
struct PlayerMiniSlotView<Content: View>: View {
    var onMeasure: (PlayerMiniSlot) -> Void
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassPlayerMiniSlot(onMeasure: onMeasure, content: content)
        } else {
            PlayerMiniSlotMeasure(compact: false, onMeasure: onMeasure) {
                content(false).modifier(PlayerMiniGlass())
            }
        }
    }
}

@available(iOS 26, *)
private struct GlassPlayerMiniSlot<Content: View>: View {
    var onMeasure: (PlayerMiniSlot) -> Void
    @ViewBuilder var content: (Bool) -> Content
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    var body: some View {
        let compact = placement == .inline
        // No app material here: inline/expanded backing is drawn by the native
        // accessory. Adding another glass surface cannot remove an opaque host.
        PlayerMiniSlotMeasure(compact: compact, onMeasure: onMeasure) { content(compact) }
    }
}

private struct PlayerMiniSlotMeasure<Content: View>: View {
    var compact: Bool
    var onMeasure: (PlayerMiniSlot) -> Void
    @ViewBuilder var content: () -> Content
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 56

    var body: some View {
        content()
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
    }

    private func report(_ slot: PlayerMiniSlot) {
        // Measurement is only a target for player expansion/collapse. The
        // visible resting mini stays in this host during native minimization.
        DispatchQueue.main.async { onMeasure(slot) }
    }
}
