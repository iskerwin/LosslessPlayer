import SwiftUI
import UIKit

/// Which pans may start pulling the player card down. Only a mostly
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

/// Presents the player full screen from UIKit. On iOS 18 and later the card
/// grows out of the mini, follows a pull straight down and shrinks back into
/// the mini (`PlayerCardTransition`), as in Music; the system zoom shrank the
/// page while it was pulled. iOS 17 uses the plain full-screen cover.
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
            PlayerOpenTrace.view = presenter.view
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
        /// The current dismissal was asked for by the app, not a user pull.
        private var dismissing = false

        /// Holds the transition delegate, which UIKit references weakly.
        private var transition: PlayerCardTransition?
        private var drag: PlayerCardDrag?

        func sync() {
            if isPresented.wrappedValue != (host != nil) {
                PlayerOpenTrace.note("sync want=\(isPresented.wrappedValue) host=\(host != nil) dismissing=\(dismissing)")
            }
            if isPresented.wrappedValue {
                if host == nil { present() }
            } else if let host, !dismissing {
                dismissing = true
                host.dismiss(animated: true)
            }
        }

        private func present() {
            guard let presenter, let window = presenter.view.window else {
                PlayerOpenTrace.note(presenter == nil ? "present: no presenter" : "present: no window")
                return
            }
            let host = PlayerHostingController(rootView: makePlayer())
            host.modalPresentationStyle = .fullScreen
            host.overrideUserInterfaceStyle = .dark
            host.onAppeared = { [weak self] in self?.onSettled() }
            host.onDismissed = { [weak self] in self?.didDismiss() }
            if #available(iOS 18, *) {
                let transition = PlayerCardTransition()
                transition.source = { [weak anchor = self.anchor, weak window] in anchor?.source(in: window) }
                self.transition = transition
                host.modalPresentationStyle = .custom
                host.modalPresentationCapturesStatusBarAppearance = true
                host.transitioningDelegate = transition
                let drag = PlayerCardDrag(card: host.view)
                // A pull closes like the system pull did: didDismiss reports it.
                drag.attach { [weak host] in host?.dismiss(animated: true) }
                self.drag = drag
            }
            self.host = host
            PlayerOpenTrace.note("present: presenting=\(presenter.presentedViewController != nil) beingDismissed=\(presenter.isBeingDismissed)")
            presenter.present(host, animated: true)
        }

        private func didDismiss() {
            PlayerOpenTrace.note("dismissed")
            host = nil
            drag = nil
            transition = nil
            // "跟手": a pull on the card closed it; "程序": the app did.
            presenter?.view.accessibilityValue = dismissing ? "程序" : "跟手"
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
        PlayerOpenTrace.note("appeared")
        onAppeared()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onDismissed() }
    }
}

/// Screenshot-mode trace of the open path, for UI tests that lose a mini tap.
/// UIKit only: SwiftUI state here would re-run the shell and replace the mini.
@MainActor enum PlayerOpenTrace {
    static weak var view: UIView?
    private static var events: [String] = []
    private static let start = ProcessInfo.processInfo.systemUptime

    static func note(_ event: String) {
        guard ScreenshotFixture.enabled else { return }
        let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        events.append("\(ms) \(event)")
        print("[PlayerOpenTrace] \(ms) \(event)")
        events = Array(events.suffix(16))
        view?.accessibilityLabel = events.joined(separator: " | ")
    }
}
