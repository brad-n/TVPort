// What the Top Shelf shows, decided apart from TVServices so it can be checked on its own: "Recently Played" (up to 8, newest first, only games that were played) then "All Games" (A-Z).
// An item's action opens the game itself when its app answers its URL scheme: SwitchTV writes that set (launchable) on every refresh and it is the truth once it exists, so a deleted game gets the details page, not a dead tile.
// Only before SwitchTV has ever written it does "was played" stand in for it (playing proves the app was there).
import Foundation

struct ShelfItem: Equatable {
    let identifier: String
    let titleID: String
    let name: String
    let image: URL?
    let action: URL
}

struct ShelfSection: Equatable {
    let title: String
    let items: [ShelfItem]
}

enum Shelf {
    static let recentLimit = 8
    static let allLimit = 24
    static let openScheme = "switchtv"

    /// switchtv://game/<TITLE ID>: SwitchTV opens that game's details page.
    static func detailsURL(_ titleID: String) -> URL { URL(string: "\(openScheme)://game/\(titleID.uppercased())")! }

    static func titleID(from url: URL) -> String? {
        guard url.scheme == openScheme, url.host == "game" else { return nil }
        let id = url.lastPathComponent.uppercased()
        return id.count == 16 && id.allSatisfy(\.isHexDigit) ? id : nil
    }

    static func sections(catalog: Catalog, lastPlayed: [String: Double], launchable: Set<String>?, imageFolder: URL) -> [ShelfSection] {
        let playable = launchable ?? Set(lastPlayed.keys)
        func item(_ game: CatalogGame, prefix: String) -> ShelfItem {
            let image = game.card.isEmpty ? nil : imageFolder.appendingPathComponent(game.card)
            let action = playable.contains(game.titleID) ? (game.playURL ?? detailsURL(game.titleID)) : detailsURL(game.titleID)
            return ShelfItem(identifier: "\(prefix)-\(game.titleID)", titleID: game.titleID, name: game.name, image: image.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }, action: action)
        }
        let recent = catalog.games.filter { lastPlayed[$0.titleID] != nil }.sorted { lastPlayed[$0.titleID]! > lastPlayed[$1.titleID]! }.prefix(recentLimit)
        var sections: [ShelfSection] = []
        if !recent.isEmpty { sections.append(ShelfSection(title: "Recently Played", items: recent.map { item($0, prefix: "recent") })) }
        if !catalog.games.isEmpty { sections.append(ShelfSection(title: "All Games", items: catalog.games.prefix(allLimit).map { item($0, prefix: "all") })) }
        return sections
    }
}
