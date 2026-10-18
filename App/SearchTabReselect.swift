import SwiftUI
import UIKit

/// Detects a second tap on the already selected search tab. The first tap only changes tabs.
struct SearchTabReselect: UIViewControllerRepresentable {
    var title: String
    var onReselect: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.titleToMatch = title
        controller.onReselect = onReselect
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.titleToMatch = title
        controller.onReselect = onReselect
        controller.installIfNeeded()
    }

    final class Controller: UIViewController {
        var titleToMatch = ""
        var onReselect: (() -> Void)?
        private var proxy: Proxy?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installIfNeeded()
        }

        func installIfNeeded() {
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        private func install() {
            guard let tab = nearestTabBarController() else { return }
            if let proxy = tab.delegate as? Proxy {
                proxy.titleToMatch = titleToMatch
                proxy.onReselect = { [weak self] in self?.onReselect?() }
                self.proxy = proxy
                return
            }
            let proxy = Proxy(original: tab.delegate, titleToMatch: titleToMatch) { [weak self] in
                self?.onReselect?()
            }
            self.proxy = proxy
            tab.delegate = proxy
        }

        private func nearestTabBarController() -> UITabBarController? {
            var current: UIViewController? = self
            while let next = current {
                if let tab = next.tabBarController { return tab }
                current = next.parent
            }
            return nil
        }
    }

    final class Proxy: NSObject, UITabBarControllerDelegate {
        weak var original: UITabBarControllerDelegate?
        var titleToMatch: String
        var onReselect: () -> Void

        init(original: UITabBarControllerDelegate?, titleToMatch: String, onReselect: @escaping () -> Void) {
            self.original = original
            self.titleToMatch = titleToMatch
            self.onReselect = onReselect
        }

        func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            if tabBarController.selectedViewController === viewController,
               viewController.tabBarItem.title == titleToMatch {
                onReselect()
            }
            if let original, original.responds(to: #selector(UITabBarControllerDelegate.tabBarController(_:shouldSelect:))) {
                return original.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
            }
            return true
        }

        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return original?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let original, original.responds(to: aSelector) { return original }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
