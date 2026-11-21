import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Which pans may start the zoom's interactive dismissal. Only a mostly
/// downward pull closes the player; sideways drags belong to the artwork's
/// skip swipe. SwiftUI's zoom cover let the system pan take a rightward
/// swipe and close the player instead of going back a track.
enum PlayerDismissPan {
    static func shouldBegin(velocity: CGVector) -> Bool {
        velocity.dy > 0 && velocity.dy >= abs(velocity.dx)
    }
}

/// How far a pull must travel to close the player when the app, not the
/// zoom's dismissal, closes it: on iOS 17, and on later systems when the
/// dismissal dropped the pull.
enum PlayerPullClose {
    static func closes(_ translation: CGSize) -> Bool {
        translation.height > 90 && translation.height > abs(translation.width) * 1.5
    }
}

/// Closes the player when a long downward pull ends and nothing took it.
/// The zoom's swipe-down dismissal gives up when the first move arrives as
/// one long jump, without asking `interactiveDismissShouldBegin`, and the
/// player stayed open (run 44778299804: a 45 pt first move). It only watches
/// touches and never recognizes, so it cannot take a pull from the
/// dismissal, a scroll view or a control.
private final class DroppedPullClose: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let onClose: () -> Void
    private var start: CGPoint?

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard start == nil, event.allTouches?.count == 1, let touch = touches.first else {
            state = .failed
            return
        }
        start = touch.location(in: nil)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        defer { state = .failed }
        guard let start, let touch = touches.first else { return }
        let taken = touch.gestureRecognizers?.contains { other in
            other !== self && [.began, .changed, .ended].contains(other.state)
        } ?? false
        let end = touch.location(in: nil)
        if !taken && PlayerPullClose.closes(CGSize(width: end.x - start.x, height: end.y - start.y)) {
            onClose()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func reset() {
        start = nil
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// What the player zooms out of and back into. On iOS 26 that is the native
/// bottom accessory, found from UIKit when the player opens: a UIKit view
/// inside the accessory's content made the system replace the accessory on
/// updates, and a tap landing during the swap was lost. Earlier systems have
/// no accessory, so the inset mini marks itself with `PlayerZoomSource`.
@MainActor final class PlayerZoomAnchor {
    weak var view: UIView?

    func source(in window: UIWindow?) -> UIView? {
        if let view { return view }
        guard #available(iOS 26, *), let root = window?.rootViewController else { return nil }
        var stack = [root]
        while let controller = stack.popLast() {
            if let tabs = controller as? UITabBarController, let accessory = tabs.bottomAccessory {
                return accessory.contentView
            }
            stack += controller.children
        }
        return nil
    }
}

/// Marks the view it backs as the zoom source. Only for the pre-iOS 26
/// inset mini; never inside the native accessory.
struct PlayerZoomSource: UIViewRepresentable {
    var anchor: PlayerZoomAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        anchor.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        anchor.view = view
    }
}

/// Presents the player full screen from UIKit, zooming from the mini on
/// iOS 18 and later. UIKit is needed for `interactiveDismissShouldBegin`,
/// which SwiftUI's zoom transition does not expose.
struct PlayerPresentation<Player: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var anchor: PlayerZoomAnchor
    /// Called when the presentation has finished appearing.
    var onSettled: () -> Void
    @ViewBuilder var player: () -> Player

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let presenter = UIViewController()
        presenter.view.isUserInteractionEnabled = false
        if ScreenshotFixture.enabled {
            // UI tests read how the player last closed. UIKit only: a
            // SwiftUI state here would re-run the shell and replace the mini.
            presenter.view.isAccessibilityElement = true
            presenter.view.accessibilityIdentifier = "player-last-close"
        }
        return presenter
    }

    func updateUIViewController(_ presenter: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.presenter = presenter
        coordinator.anchor = anchor
        coordinator.isPresented = $isPresented
        coordinator.onSettled = onSettled
        coordinator.makePlayer = { AnyView(player().tint(MusicTheme.accent)) }
        coordinator.host?.rootView = coordinator.makePlayer()
        coordinator.sync()
    }

    @MainActor final class Coordinator {
        weak var presenter: UIViewController?
        var anchor: PlayerZoomAnchor?
        var isPresented: Binding<Bool> = .constant(false)
        var onSettled: () -> Void = {}
        var makePlayer: () -> AnyView = { AnyView(EmptyView()) }
        fileprivate var host: PlayerHostingController?
        /// Why the app is closing the player, read by UI tests: "程序" when
        /// asked to, "兜底" for a pull the dismissal dropped. Nil while the
        /// system's pull closes it ("跟手").
        private var closing: String?

        func sync() {
            if isPresented.wrappedValue {
                if host == nil { present() }
            } else {
                close(as: "程序")
            }
        }

        private func close(as reason: String) {
            guard let host, closing == nil else { return }
            closing = reason
            host.dismiss(animated: true)
        }

        private func closeDroppedPull() {
            guard let host, !host.isBeingDismissed, host.transitionCoordinator == nil else { return }
            close(as: "兜底")
            isPresented.wrappedValue = false
        }

        private func present() {
            guard let presenter, let window = presenter.view.window else { return }
            let host = PlayerHostingController(rootView: makePlayer())
            host.modalPresentationStyle = .fullScreen
            host.overrideUserInterfaceStyle = .dark
            host.onAppeared = { [weak self] in self?.onSettled() }
            host.onDismissed = { [weak self] in self?.didDismiss() }
            if #available(iOS 18, *) {
                let options = UIViewController.Transition.ZoomOptions()
                options.interactiveDismissShouldBegin = { context in
                    PlayerDismissPan.shouldBegin(velocity: context.velocity)
                }
                host.preferredTransition = .zoom(options: options) { [weak anchor = self.anchor, weak window] _ in
                    MainActor.assumeIsolated { anchor?.source(in: window) }
                }
                host.view.addGestureRecognizer(DroppedPullClose { [weak self] in self?.closeDroppedPull() })
            }
            self.host = host
            presenter.present(host, animated: true)
        }

        private func didDismiss() {
            host = nil
            presenter?.view.accessibilityValue = closing ?? "跟手"
            if closing != nil {
                closing = nil
                // A reopen requested while closing is honoured now.
                sync()
            } else {
                // The user pulled the player down.
                isPresented.wrappedValue = false
            }
        }
    }
}

private final class PlayerHostingController: UIHostingController<AnyView> {
    var onAppeared: () -> Void = {}
    var onDismissed: () -> Void = {}

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppeared()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onDismissed() }
    }
}
