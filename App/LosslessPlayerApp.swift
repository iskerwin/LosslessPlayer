import SwiftUI

@main
struct LosslessPlayerApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var player: PlayerStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = LibraryStore()
        _library = StateObject(wrappedValue: library)
        _player = StateObject(wrappedValue: PlayerStore(library: library))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library, player: player)
                .tint(.orange)
                .onChange(of: library.tracks) { _, _ in player.reconcileLibrary() }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { library.remember(id: player.current?.id, position: player.position) }
                }
        }
    }
}
