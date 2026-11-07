import SwiftUI

@main
struct SwitchTVApp: App {
    @StateObject private var library = Library()
    @StateObject private var router = Router()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $router.path) {
                HomeView()
                    .navigationDestination(for: CatalogGame.self) { DetailView(game: $0) }
            }
            .environmentObject(library)
            .environmentObject(router)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .background(Theme.background.ignoresSafeArea())
            .onChange(of: phase) { _, new in if new == .active { library.refresh() } }
            .onOpenURL { url in   // switchtv://game/<title ID>: the Top Shelf's way in for a game that cannot be opened directly
                if let id = Shelf.titleID(from: url), let game = library.catalog.game(id) { router.show(game) }
            }
            .alert("Can\u{2019}t play yet", isPresented: Binding(get: { library.notice != nil }, set: { if !$0 { library.notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(library.notice ?? "") }
        }
    }
}
