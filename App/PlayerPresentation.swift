import SwiftUI
import UIKit

/// Which pans may start the zoom's interactive dismissal. Only a mostly
/// downward pull closes the player; sideways drags belong to the artwork's
/// skip swipe. SwiftUI's zoom cover let the system pan take a rightward
/// swipe and close the player instead of going back a track.
enum PlayerDismissPan {
    static func shouldBegin(velocity: CGVector) -> Bool {
        velocity.dy > 0 && velocity.dy >= abs(velocity.dx)
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
        /// The current dismissal was asked for by the app, not a user pull.
        private var dismissing = false

        func sync() {
            if isPresented.wrappedValue {
                if host == nil { present() }
            } else if let host, !dismissing {
                dismissing = true
                host.dismiss(animated: true)
            }
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
            }
            self.host = host
            presenter.present(host, animated: true)
        }

        private func didDismiss() {
            host = nil
            if dismissing {
                dismissing = false
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
