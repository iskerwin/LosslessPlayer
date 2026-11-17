import UIKit

/// The pull-down on the player card, as in Music: the full-width card moves
/// straight down with the finger and never shrinks while held. Releasing far
/// or fast enough closes it into the mini; otherwise it springs back.
@MainActor final class PlayerCardDrag {
    /// Rounded top corners while the card is lifted off the screen edge.
    static let cornerRadius: CGFloat = 40

    static func closes(offset: CGFloat, velocity: CGFloat, height: CGFloat) -> Bool {
        if velocity > 900 { return true }
        if velocity < -300 { return false }
        return offset > height * 0.25
    }

    private weak var card: UIView?

    init(card: UIView) {
        self.card = card
    }

    /// Follows the finger 1:1, never above the resting position.
    func update(translation: CGFloat) {
        guard let card else { return }
        let offset = max(0, translation)
        card.transform = CGAffineTransform(translationX: 0, y: offset)
        card.layer.cornerRadius = offset > 0 ? Self.cornerRadius : 0
        card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.layer.masksToBounds = offset > 0
    }

    /// True when the release should close the card. Otherwise it springs back.
    func end(translation: CGFloat, velocity: CGFloat) -> Bool {
        guard let card else { return false }
        let offset = max(0, translation)
        if Self.closes(offset: offset, velocity: velocity, height: card.bounds.height) { return true }
        UIView.animate(springDuration: 0.4, bounce: 0.15, initialSpringVelocity: 0) {
            card.transform = .identity
        } completion: { _ in
            card.layer.cornerRadius = 0
            card.layer.masksToBounds = false
        }
        return false
    }
}

/// Opens the player by growing the card out of the mini and closes it by
/// shrinking the card back into the mini, cross-fading the mini's content.
/// A close that starts from a pull continues from where the finger left the
/// card. With Reduce Motion both directions cross-fade in place.
@MainActor final class PlayerCardTransition: NSObject, UIViewControllerTransitioningDelegate,
    UIViewControllerAnimatedTransitioning {
    /// The mini to grow from and shrink into, or nil when it is not on screen.
    var source: () -> UIView? = { nil }
    private var presenting = true

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        self.presenting = true
        return self
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        presenting = false
        return self
    }

    nonisolated func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        0.45
    }

    nonisolated func animateTransition(using context: UIViewControllerContextTransitioning) {
        MainActor.assumeIsolated { run(context) }
    }

    private func run(_ context: UIViewControllerContextTransitioning) {
        let container = context.containerView
        let key: UITransitionContextViewKey = presenting ? .to : .from
        guard let player = context.view(forKey: key) else {
            context.completeTransition(!context.transitionWasCancelled)
            return
        }
        let full = container.bounds
        // A pull leaves the card translated; the close continues from there.
        let pulled = presenting ? 0 : player.transform.ty
        player.transform = .identity
        player.layer.cornerRadius = 0
        player.layer.masksToBounds = false

        let mini = source()
        let target = mini.flatMap { view -> CGRect? in
            let frame = view.convert(view.bounds, to: container)
            return frame.width > 0 && frame.height > 0 && frame.intersects(full) ? frame : nil
        }
        guard let target, !UIAccessibility.isReduceMotionEnabled else {
            fade(player, in: container, context: context)
            return
        }

        // The card clips the player, which scales by the width ratio so its
        // content shrinks evenly while the card's height follows the mini.
        let card = UIView(frame: full)
        card.clipsToBounds = true
        card.layer.cornerCurve = .continuous
        container.addSubview(card)
        player.frame = full
        card.addSubview(player)
        let snapshot = mini?.snapshotView(afterScreenUpdates: false)
        if let snapshot {
            snapshot.frame = CGRect(origin: .zero, size: target.size)
            card.addSubview(snapshot)
        }
        mini?.alpha = 0

        let scale = target.width / full.width
        let shrunk = CGAffineTransform(translationX: -full.width * (1 - scale) / 2,
                                       y: -full.height * (1 - scale) / 2).scaledBy(x: scale, y: scale)
        let open = {
            card.frame = full
            card.layer.cornerRadius = 0
            player.transform = .identity
            player.alpha = 1
            // Scaled up to the card's width, pinned to its top-left corner.
            let grow = 1 / scale
            snapshot?.transform = CGAffineTransform(translationX: target.width * (grow - 1) / 2,
                                                    y: target.height * (grow - 1) / 2).scaledBy(x: grow, y: grow)
            snapshot?.alpha = 0
        }
        let closed = {
            card.frame = target
            card.layer.cornerRadius = target.height / 2
            player.transform = shrunk
            player.alpha = 0
            snapshot?.transform = .identity
            snapshot?.alpha = 1
        }
        if presenting {
            closed()
        } else {
            open()
            card.frame = full.offsetBy(dx: 0, dy: pulled)
            card.layer.cornerRadius = pulled > 0 ? PlayerCardDrag.cornerRadius : 0
        }
        UIView.animate(springDuration: transitionDuration(using: context), bounce: 0) {
            if self.presenting { open() } else { closed() }
        } completion: { _ in
            let finished = !context.transitionWasCancelled
            mini?.alpha = 1
            snapshot?.removeFromSuperview()
            player.transform = .identity
            player.alpha = 1
            if self.presenting && finished {
                player.frame = context.finalFrame(for: context.viewController(forKey: .to)!)
                container.addSubview(player)
            }
            card.removeFromSuperview()
            context.completeTransition(finished)
        }
    }

    private func fade(_ player: UIView, in container: UIView, context: UIViewControllerContextTransitioning) {
        if presenting {
            player.frame = context.finalFrame(for: context.viewController(forKey: .to)!)
            player.alpha = 0
            container.addSubview(player)
        }
        UIView.animate(withDuration: 0.25) {
            player.alpha = self.presenting ? 1 : 0
        } completion: { _ in
            player.alpha = 1
            context.completeTransition(!context.transitionWasCancelled)
        }
    }
}
