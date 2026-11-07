// The games SwitchTV lists: Catalog/catalog.json and its images, written by `backend.py switchtv build` into the app and into its Top Shelf extension. Nothing is fetched at run time except screenshots.
// Foundation only: SwitchTV, the Top Shelf extension and the command-line checks (tvport/tests/test_switchtv_app.py) all compile this file.
import Foundation

struct CatalogGame: Codable, Identifiable, Hashable {
    let titleID: String
    let name: String
    let publisher: String?
    let releaseDate: String?     // yyyy-MM-dd
    let numberOfPlayers: Int?
    let genres: [String]
    let summary: String?
    let intro: String?
    let bundleID: String
    let scheme: String           // switchtv-<title ID in lowercase>
    let card: String             // image paths, relative to Catalog
    let banner: String
    let screenshots: [String]    // URLs

    var id: String { titleID }
    var playURL: URL? { URL(string: "\(scheme)://play") }

    enum CodingKeys: String, CodingKey {
        case titleID, name, publisher, releaseDate, numberOfPlayers, genres, summary = "description", intro, bundleID, scheme, card, banner, screenshots
    }

    var releaseYear: String? {
        guard let releaseDate, releaseDate.count >= 4, releaseDate.prefix(4).allSatisfy(\.isNumber) else { return nil }
        return String(releaseDate.prefix(4))
    }

    var releaseText: String? {
        guard let releaseDate else { return nil }
        let parse = DateFormatter(); parse.dateFormat = "yyyy-MM-dd"; parse.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parse.date(from: releaseDate) else { return nil }
        return date.formatted(date: .long, time: .omitted)
    }

    var playersText: String? {
        guard let n = numberOfPlayers, n > 0 else { return nil }
        return n == 1 ? "1 player" : "1-\(n) players"
    }

    /// The text under the title: publisher, year, players.
    var metaText: String { [publisher, releaseYear, playersText].compactMap { $0 }.joined(separator: "  \u{2022}  ") }

    /// The description, as long as the shop gave it.
    var blurb: String? { summary ?? intro }
}

struct Catalog: Codable {
    let generated: String
    let games: [CatalogGame]

    static var folder: URL { Bundle.main.resourceURL!.appendingPathComponent("Catalog", isDirectory: true) }

    /// A-Z by name.
    static func load(from folder: URL = Catalog.folder) -> Catalog {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("catalog.json")),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return Catalog(generated: "", games: []) }
        return Catalog(generated: catalog.generated, games: catalog.games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    func game(_ titleID: String) -> CatalogGame? { games.first { $0.titleID.caseInsensitiveCompare(titleID) == .orderedSame } }

    /// Genres that have at least two games, most games first.
    var genreRows: [(genre: String, games: [CatalogGame])] {
        var byGenre: [String: [CatalogGame]] = [:]
        for game in games { for genre in game.genres { byGenre[genre, default: []].append(game) } }
        return byGenre.filter { $0.value.count >= 2 }.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }.map { ($0.key, $0.value) }
    }
}
