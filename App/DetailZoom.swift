import SwiftUI

/// Include the grid as well as the identity: the same album can appear in both
/// Recently Added and the album index within one navigation stack.
struct DetailZoomRoute: Hashable {
    enum Grid: Hashable {
        case recentAlbums, albumIndex, playlists
    }

    var route: LibraryRoute
    var grid: Grid
}

private struct DetailZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var detailZoomNamespace: Namespace.ID? {
        get { self[DetailZoomNamespaceKey.self] }
        set { self[DetailZoomNamespaceKey.self] = newValue }
    }
}

/// A value link pushes onto the owning tab's existing NavigationStack.
/// Only the artwork is a zoom source; context menus remain on the whole cell.
struct DetailZoomLink<Artwork: View, Label: View>: View {
    var route: LibraryRoute
    var grid: DetailZoomRoute.Grid
    @ViewBuilder var artwork: () -> Artwork
    @ViewBuilder var label: (AnyView) -> Label
    @Environment(\.detailZoomNamespace) private var namespace

    var body: some View {
        let detail = DetailZoomRoute(route: route, grid: grid)
        NavigationLink(value: detail) {
            label(AnyView(artwork().modifier(DetailZoomSource(id: detail, namespace: namespace))))
        }
    }
}

struct DetailZoomSource: ViewModifier {
    var id: DetailZoomRoute
    var namespace: Namespace.ID?

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

struct DetailZoomDestination: ViewModifier {
    var id: DetailZoomRoute
    var namespace: Namespace.ID

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}
