// What SwitchTV knows about the games: the catalogue, which game apps can be opened (canOpenURL), and when each was last played. Last-played times live in the shared keychain group
// (Shared/SharedStore.swift: SwitchTV and the game apps write them, the Top Shelf reads them) and are mirrored in UserDefaults in case the group is not available.
import SwiftUI
import TVServices
import UIKit

@MainActor
final class Library: ObservableObject {
    @Published private(set) var catalog = Catalog.load()
    @Published private(set) var lastPlayed: [String: Double] = UserDefaults.standard.dictionary(forKey: Library.key) as? [String: Double] ?? [:]
    @Published private(set) var installed: Set<String> = []
    /// A message for the owner (an alert): set when a game cannot be opened.
    @Published var notice: String?
    private let store = SharedStore()
    private static let key = "lastLaunched"

    init() { refresh() }

    /// Most recently played first (from here or from the game itself).
    var recent: [CatalogGame] {
        catalog.games.filter { lastPlayed[$0.titleID] != nil }.sorted { lastPlayed[$0.titleID]! > lastPlayed[$1.titleID]! }
    }

    /// The hero before anything has focus: the game played last, else the first.
    var featured: CatalogGame? { recent.first ?? catalog.games.first }

    func canPlay(_ game: CatalogGame) -> Bool { installed.contains(game.titleID) }

    static func rebuildMessage(_ game: CatalogGame) -> String { "Rebuild \(game.name) in TVPort to play it from SwitchTV" }

    /// Re-reads what changes while SwitchTV is away: which game apps exist and what the games recorded. canOpenURL is true only for an installed game that declares its switchtv-<title ID> scheme (listed in LSApplicationQueriesSchemes).
    func refresh() {
        installed = Set(catalog.games.filter { game in game.playURL.map { UIApplication.shared.canOpenURL($0) } ?? false }.map(\.titleID))
        var merged = lastPlayed
        for (id, time) in store?.lastPlayed() ?? [:] where time > (merged[id] ?? 0) { merged[id] = time }
        if merged != lastPlayed { lastPlayed = merged; UserDefaults.standard.set(merged, forKey: Self.key) }
        if let store {
            for (id, time) in merged { store.record(id, at: Date(timeIntervalSince1970: time)) }   // a record the group lost comes back from the mirror
            if store.launchable() != installed { store.setLaunchable(installed); TVTopShelfContentProvider.topShelfContentDidChange() }
        }
    }

    /// Select on a poster: open the game, or say why it cannot be opened. Never a silent no-op.
    func select(_ game: CatalogGame) {
        guard canPlay(game), let url = game.playURL else { notice = Self.rebuildMessage(game); return }
        UIApplication.shared.open(url) { [weak self] opened in
            Task { @MainActor in
                guard let self else { return }
                if opened { self.markPlayed(game) } else { self.notice = "\(game.name) could not be opened. Rebuild it in TVPort and try again." }
            }
        }
    }

    private func markPlayed(_ game: CatalogGame) {
        let now = Date()
        lastPlayed[game.titleID] = now.timeIntervalSince1970
        UserDefaults.standard.set(lastPlayed, forKey: Self.key)
        store?.record(game.titleID, at: now)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }
}

/// The details page that is showing (a stack of at most one), opened by long-press / Play-Pause on a poster or by a switchtv://game/<title ID> link from the Top Shelf.
@MainActor
final class Router: ObservableObject {
    @Published var path: [CatalogGame] = []
    func show(_ game: CatalogGame) { path = [game] }
}
