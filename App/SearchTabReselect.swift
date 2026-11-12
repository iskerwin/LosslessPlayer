import SwiftUI
import UIKit

/// Detects a second tap on an already selected tab. The first tap only changes tabs.
/// Each title keeps its own action, so search and playlists can both listen.
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

    /// Glass tabs keep the visible name on `UITab`. A blank string is not a title.
    enum Match {
        static func title(itemTitle: String?, tabTitle: String?, accessibilityLabel: String?) -> String? {
            // The glass tab bar draws `UITab.title`. The bar item is a fallback for older tabs.
            for candidate in [tabTitle, itemTitle, accessibilityLabel] {
                let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty { return trimmed }
            }
            return nil
        }

        static func title(for viewController: UIViewController) -> String? {
            var tabTitle: String?
            if #available(iOS 18, *) {
                tabTitle = viewController.tab?.title
            }
            return title(itemTitle: viewController.tabBarItem.title,
                         tabTitle: tabTitle,
                         accessibilityLabel: viewController.tabBarItem.accessibilityLabel)
        }

        @available(iOS 18, *)
        static func title(for tab: UITab) -> String? {
            title(itemTitle: tab.viewController?.tabBarItem.title,
                  tabTitle: tab.title,
                  accessibilityLabel: tab.viewController?.tabBarItem.accessibilityLabel)
        }
    }

    /// The hook is a background of the tab view, so it sits beside the tab
    /// controller. Walking `parent` never finds it.
    enum Lookup {
        static func controller(startingAt start: UIViewController, roots: [UIViewController]) -> UITabBarController? {
            if let tab = ancestor(of: start) { return tab }
            var seen = Set<ObjectIdentifier>()
            for root in roots {
                guard seen.insert(ObjectIdentifier(root)).inserted else { continue }
                if let tab = descendant(of: root) { return tab }
            }
            return nil
        }

        static func ancestor(of start: UIViewController) -> UITabBarController? {
            var current: UIViewController? = start
            while let next = current {
                if let tab = next as? UITabBarController { return tab }
                if let tab = next.tabBarController { return tab }
                current = next.parent
            }
            return nil
        }

        static func descendant(of controller: UIViewController) -> UITabBarController? {
            if let tab = controller as? UITabBarController { return tab }
            for child in controller.children {
                if let found = descendant(of: child) { return found }
            }
            if let presented = controller.presentedViewController {
                return descendant(of: presented)
            }
            return nil
        }
    }

    @available(iOS 18, *)
    static func same(_ lhs: UITab?, _ rhs: UITab?) -> Bool {
        guard let lhs, let rhs else { return false }
        if lhs === rhs { return true }
        let left = lhs.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return !left.isEmpty && left == right
    }

    final class Controller: UIViewController {
        var titleToMatch = ""
        var onReselect: (() -> Void)?
        private var proxy: Proxy?

        override func loadView() {
            let anchor = SearchTabReselect.AnchorView()
            anchor.isUserInteractionEnabled = false
            anchor.backgroundColor = .clear
            anchor.movedToWindow = { [weak self] in self?.installIfNeeded() }
            view = anchor
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installIfNeeded()
        }

        func installIfNeeded() {
            DispatchQueue.main.async { [weak self] in
                self?.install()
                // SwiftUI may assign its own delegate in this turn. Wrap that one too.
                DispatchQueue.main.async { [weak self] in self?.install() }
            }
        }

        /// `roots` is the surrounding hierarchy when this controller is not inside the tab bar.
        func install(in supplied: [UIViewController]? = nil) {
            let roots = supplied ?? Self.candidateRoots(for: self)
            guard let tab = SearchTabReselect.Lookup.controller(startingAt: self, roots: roots) else { return }
            let proxy: Proxy
            if let existing = tab.delegate as? Proxy {
                proxy = existing
            } else {
                proxy = self.proxy ?? Proxy(original: tab.delegate)
                if let delegate = tab.delegate, !(delegate is Proxy) {
                    proxy.original = delegate
                }
            }
            proxy.handlers[titleToMatch] = { [weak self] in self?.onReselect?() }
            self.proxy = proxy
            if tab.delegate !== proxy { tab.delegate = proxy }
        }

        private static func candidateRoots(for controller: UIViewController) -> [UIViewController] {
            var roots: [UIViewController] = []
            if let root = controller.viewIfLoaded?.window?.rootViewController {
                roots.append(root)
            }
            var top: UIViewController? = controller
            while let parent = top?.parent { top = parent }
            if let top { roots.append(top) }
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows where window.isKeyWindow {
                    if let root = window.rootViewController { roots.append(root) }
                }
            }
            return roots
        }
    }

    final class AnchorView: UIView {
        var movedToWindow: () -> Void = {}
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            movedToWindow()
        }
    }

    final class Proxy: NSObject, UITabBarControllerDelegate {
        weak var original: UITabBarControllerDelegate?
        /// One action per tab title. A second tab must not replace the first.
        var handlers: [String: () -> Void] = [:]
        /// `shouldSelect` and `didSelectTab` both run for one tap. Deliver once.
        private var delivered: Set<String> = []

        init(original: UITabBarControllerDelegate?) {
            self.original = original
        }

        func deliver(_ title: String?) {
            guard let title, let action = handlers[title] else { return }
            guard delivered.insert(title).inserted else { return }
            action()
            DispatchQueue.main.async { [weak self] in
                self?.delivered.remove(title)
            }
        }

        func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            let reselect = tabBarController.selectedViewController === viewController
            let allowed = forwardShouldSelect(tabBarController, viewController)
            if allowed, reselect { deliver(SearchTabReselect.Match.title(for: viewController)) }
            return allowed
        }

        @available(iOS 18.0, *)
        func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            let reselect = SearchTabReselect.same(tabBarController.selectedTab, tab) || sameController(tabBarController, tab)
            let allowed = forwardShouldSelectTab(tabBarController, tab)
            if allowed, reselect { deliver(SearchTabReselect.Match.title(for: tab)) }
            return allowed
        }

        @available(iOS 18.0, *)
        func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
            if SearchTabReselect.same(previousTab, selectedTab) {
                deliver(SearchTabReselect.Match.title(for: selectedTab))
            }
            original?.tabBarController?(tabBarController, didSelectTab: selectedTab, previousTab: previousTab)
        }

        private func forwardShouldSelect(_ tabBarController: UITabBarController, _ viewController: UIViewController) -> Bool {
            if let original, original.responds(to: #selector(UITabBarControllerDelegate.tabBarController(_:shouldSelect:))) {
                return original.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
            }
            return true
        }

        @available(iOS 18.0, *)
        private func forwardShouldSelectTab(_ tabBarController: UITabBarController, _ tab: UITab) -> Bool {
            if let original, original.responds(to: #selector(UITabBarControllerDelegate.tabBarController(_:shouldSelectTab:))) {
                return original.tabBarController?(tabBarController, shouldSelectTab: tab) ?? true
            }
            return true
        }

        @available(iOS 18.0, *)
        private func sameController(_ tabBarController: UITabBarController, _ tab: UITab) -> Bool {
            guard let current = tabBarController.selectedViewController,
                  let next = tab.viewController else { return false }
            return current === next
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
