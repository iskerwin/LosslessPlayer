import SwiftUI

/// Shared by the resting mini in either host.
/// Ordinary drag priority preserves taps on the mini's transport buttons.
struct MiniPlayerReopenGesture: Gesture {
    var onReopen: () -> Void

    var body: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onEnded { value in
                if value.translation.height <= -16,
                   -value.translation.height > abs(value.translation.width) * 1.5 {
                    onReopen()
                }
            }
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

/// Distinct native accessory minis that appeared, and the track the mini
/// last showed. A replaced mini drops a tap that lands during the swap, so
/// regression tests assert that updates reach the mounted mini instead. A
/// reattach of the same mini appears again without adding an instance.
/// Kept per player: a mini from an earlier test's window can still report
/// after `reset()`, and must not count against the mini under test.
@MainActor enum MiniAccessoryProbe {
    private static var mounted: [ObjectIdentifier: Set<UUID>] = [:]
    private static var shown: [ObjectIdentifier: UUID] = [:]

    static func appeared(_ instance: UUID, for player: PlayerStore) {
        mounted[ObjectIdentifier(player), default: []].insert(instance)
    }

    static func showed(_ trackID: UUID?, for player: PlayerStore) {
        shown[ObjectIdentifier(player)] = trackID
    }

    static func instances(for player: PlayerStore) -> Set<UUID> {
        mounted[ObjectIdentifier(player)] ?? []
    }

    static func trackID(for player: PlayerStore) -> UUID? {
        shown[ObjectIdentifier(player)]
    }

    static func reset() {
        mounted = [:]
        shown = [:]
    }
}

/// Sizes the resting mini for the native accessory (or the pre-iOS 26 inset).
struct PlayerMiniSlotView<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassPlayerMiniSlot(content: content)
        } else {
            PlayerMiniSlotSized(compact: false) { content(false).modifier(PlayerMiniGlass()) }
        }
    }
}

@available(iOS 26, *)
private struct GlassPlayerMiniSlot<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    var body: some View {
        let compact = placement == .inline
        // No app material here: inline/expanded backing is drawn by the native
        // accessory. Adding another glass surface cannot remove an opaque host.
        PlayerMiniSlotSized(compact: compact) { content(compact) }
    }
}

private struct PlayerMiniSlotSized<Content: View>: View {
    var compact: Bool
    @ViewBuilder var content: () -> Content
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 56

    var body: some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 36 : max(56, rowHeight))
    }
}
