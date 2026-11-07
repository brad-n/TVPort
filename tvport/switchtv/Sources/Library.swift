// What SwitchTV remembers locally: when each game was last started from here (UserDefaults; no App Group yet), and whether a game's app is installed.
import SwiftUI
import UIKit

@MainActor
final class Library: ObservableObject {
    @Published private(set) var catalog = Catalog.load()
    @Published private(set) var lastPlayed: [String: Double] = UserDefaults.standard.dictionary(forKey: Library.key) as? [String: Double] ?? [:]
    @Published private(set) var installed: Set<String> = []
    private static let key = "lastLaunched"

    init() { refreshInstalled() }

    /// Most recently started first.
    var continuePlaying: [CatalogGame] {
        catalog.games.filter { lastPlayed[$0.titleID] != nil }.sorted { lastPlayed[$0.titleID]! > lastPlayed[$1.titleID]! }
    }

    /// The hero: the game started last, else the first game.
    var featured: CatalogGame? { continuePlaying.first ?? catalog.games.first }

    func canPlay(_ game: CatalogGame) -> Bool { installed.contains(game.titleID) }

    /// canOpenURL is true only for an installed game that declares its switchtv-<title ID> scheme (the scheme is in LSApplicationQueriesSchemes).
    func refreshInstalled() {
        installed = Set(catalog.games.filter { game in game.playURL.map { UIApplication.shared.canOpenURL($0) } ?? false }.map(\.titleID))
    }

    func play(_ game: CatalogGame) {
        guard let url = game.playURL else { return }
        UIApplication.shared.open(url) { [weak self] opened in
            guard opened else { return }
            Task { @MainActor in
                guard let self else { return }
                self.lastPlayed[game.titleID] = Date().timeIntervalSince1970
                UserDefaults.standard.set(self.lastPlayed, forKey: Self.key)
            }
        }
    }
}
