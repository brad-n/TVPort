import SwiftUI

@main
struct SwitchTVApp: App {
    @StateObject private var library = Library()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HomeView()
                    .navigationDestination(for: CatalogGame.self) { DetailView(game: $0) }
            }
            .environmentObject(library)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .background(Theme.background.ignoresSafeArea())
            .onChange(of: phase) { _, new in if new == .active { library.refreshInstalled() } }
        }
    }
}
