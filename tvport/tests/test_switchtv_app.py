"""The code SwitchTV and its Top Shelf extension share (tvport/switchtv/Shared): the catalogue, the shared store and the Top Shelf plan, compiled for the Mac and run on their own.
Also that the game-side writer (dm/ios/SourcesTV/TVLastPlayed.m) and the store read and write the same files."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
SHARED = REPO / 'tvport/switchtv/Shared'
GAME_WRITER = REPO / 'dm/ios/SourcesTV/TVLastPlayed.m'

CHECKS = r'''
import Foundation
func game(_ id: String, _ name: String, genres: [String] = [], card: String = "") -> String {
    """
    {"titleID":"\(id)","name":"\(name)","publisher":"Nintendo","releaseDate":"2017-03-03","numberOfPlayers":4,"genres":[\(genres.map { "\"\($0)\"" }.joined(separator: ","))],"description":"d","intro":null,
     "bundleID":"b","scheme":"switchtv-\(id.lowercased())","card":"\(card)","banner":"","screenshots":[]}
    """
}
@main struct Checks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), game_writer_root = URL(fileURLWithPath: CommandLine.arguments[2])
        let fm = FileManager.default
        let catalogFolder = root.appendingPathComponent("Catalog"), images = catalogFolder.appendingPathComponent("images")
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        let ids = ["0100000000000001": "Zelda", "0100000000000002": "Arms", "0100000000000003": "Mario", "0100000000000004": "Kirby"]
        for id in ids.keys.sorted() { try Data([1]).write(to: images.appendingPathComponent("\(id)-card.jpg")) }
        let list = ids.keys.sorted().map { game($0, ids[$0]!, genres: $0 <= "0100000000000002" ? ["Action", "Rare"] : ["Action"], card: "images/\($0)-card.jpg") }.joined(separator: ",")
        try "{\"generated\":\"x\",\"games\":[\(list)]}".write(to: catalogFolder.appendingPathComponent("catalog.json"), atomically: true, encoding: .utf8)

        // catalogue: A-Z, genres with at least two games, display strings
        let catalog = Catalog.load(from: catalogFolder)
        assert(catalog.games.map(\.name) == ["Arms", "Kirby", "Mario", "Zelda"])
        assert(catalog.genreRows.map(\.genre) == ["Action", "Rare"] && catalog.genreRows.map(\.games.count) == [4, 2])
        let arms = catalog.game("0100000000000002")!
        assert(arms.releaseYear == "2017" && arms.metaText == "Nintendo  \u{2022}  2017  \u{2022}  1-4 players")
        assert(arms.playURL?.absoluteString == "switchtv-0100000000000002://play")

        // the store: records, a later one wins, launchable, junk ignored
        let store = SharedStore(backing: FolderBacking(root: root.appendingPathComponent("Keychain")))
        assert(store.lastPlayed().isEmpty && store.launchable() == nil)   // never written: nil, not empty
        store.record("0100000000000001", at: Date(timeIntervalSince1970: 1000))
        store.record("0100000000000001", at: Date(timeIntervalSince1970: 500))     // older: ignored
        store.record("0100000000000003", at: Date(timeIntervalSince1970: 3000))
        store.record("not-a-title-id", at: Date())
        assert(store.lastPlayed() == ["0100000000000001": 1000, "0100000000000003": 3000])
        store.setLaunchable(["0100000000000002"])
        assert(store.launchable() == ["0100000000000002"])
        let fallback = Shelf.sections(catalog: catalog, lastPlayed: store.lastPlayed(), launchable: store.launchable(), imageFolder: catalogFolder)
        let deleted = Dictionary(uniqueKeysWithValues: fallback[1].items.map { ($0.name, $0.action.absoluteString) })
        assert(deleted["Zelda"] == "switchtv://game/0100000000000001")                // played once, but not installed now: no dead tile
        store.setLaunchable([])
        assert(store.launchable() == [])                                                // an empty set is written and read back as empty, not nil
        assert(Shelf.sections(catalog: catalog, lastPlayed: store.lastPlayed(), launchable: store.launchable(), imageFolder: catalogFolder)[1].items.allSatisfy { $0.action.scheme == "switchtv" })
        store.setLaunchable(["0100000000000002"])

        // a record the game app wrote itself (TVLastPlayed.m, into game_writer_root) is read by the same store
        let fromGame = SharedStore(backing: FolderBacking(root: game_writer_root))
        assert(fromGame.lastPlayed() == ["0100000000000004": 7777])

        // the Top Shelf plan: Recently Played (newest first) then All Games (A-Z); launchable or played = opens the game, else SwitchTV on that game
        // without a launchable record (SwitchTV has not refreshed yet) a played game counts as installed
        let noRecord = Shelf.sections(catalog: catalog, lastPlayed: store.lastPlayed(), launchable: nil, imageFolder: catalogFolder)
        assert(noRecord[1].items.first { $0.name == "Zelda" }!.action.absoluteString == "switchtv-0100000000000001://play" && noRecord[1].items.first { $0.name == "Arms" }!.action.scheme == "switchtv")
        let sections = Shelf.sections(catalog: catalog, lastPlayed: store.lastPlayed(), launchable: store.launchable(), imageFolder: catalogFolder)
        assert(sections.map(\.title) == ["Recently Played", "All Games"])
        assert(sections[0].items.map(\.name) == ["Mario", "Zelda"])
        assert(sections[1].items.map(\.name) == ["Arms", "Kirby", "Mario", "Zelda"])
        let actions = Dictionary(uniqueKeysWithValues: sections[1].items.map { ($0.name, $0.action.absoluteString) })
        assert(actions["Arms"] == "switchtv-0100000000000002://play")                  // launchable.json
        assert(actions["Zelda"] == "switchtv://game/0100000000000001")                 // played but no longer installed (not in launchable)
        assert(actions["Kirby"] == "switchtv://game/0100000000000004")                 // neither: opens SwitchTV on the game
        assert(sections[0].items[0].image?.lastPathComponent == "0100000000000003-card.jpg")
        assert(Set(sections.flatMap(\.items).map(\.identifier)).count == 6)            // identifiers are unique across sections
        assert(Shelf.titleID(from: URL(string: "switchtv://game/0100000000000004")!) == "0100000000000004")
        assert(Shelf.titleID(from: URL(string: "switchtv://game/zzz")!) == nil && Shelf.titleID(from: URL(string: "other://game/0100000000000004")!) == nil)
        // nothing played: only All Games; many played: at most 8
        assert(Shelf.sections(catalog: catalog, lastPlayed: [:], launchable: [], imageFolder: catalogFolder).map(\.title) == ["All Games"])
        assert(Shelf.sections(catalog: Catalog(generated: "", games: []), lastPlayed: [:], launchable: [], imageFolder: catalogFolder).isEmpty)
        let many = (1...12).map { String(format: "01000000000000%02d", $0) }
        let big = Catalog(generated: "", games: many.map { try! JSONDecoder().decode(CatalogGame.self, from: game($0, "G\($0)").data(using: .utf8)!) })
        let bigShelf = Shelf.sections(catalog: big, lastPlayed: Dictionary(uniqueKeysWithValues: many.enumerated().map { ($1, Double($0)) }), launchable: [], imageFolder: catalogFolder)
        assert(bigShelf[0].items.count == 8 && bigShelf[0].items[0].titleID == "0100000000000012")
        print("PASS")
    }
}
'''

DRIVER = r'''
#import <Foundation/Foundation.h>
BOOL tv_last_played_write(BOOL (^put)(NSString *account, NSData *value), NSString *scheme, NSDate *when);
int main(int argc, char **argv) { @autoreleasepool {
    NSURL *folder = [NSURL fileURLWithPath:@(argv[1])];
    return tv_last_played_write(^BOOL(NSString *account, NSData *value) { return [value writeToURL:[folder URLByAppendingPathComponent:account] atomically:YES]; }, @"switchtv-0100000000000004", [NSDate dateWithTimeIntervalSince1970:7777]) ? 0 : 1; } }
'''


@unittest.skipUnless(sys.platform == 'darwin', 'macOS Swift required')
class SwitchTVSharedCodeTests(unittest.TestCase):
    def test_catalogue_store_and_top_shelf_plan(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'Checks.swift').write_text(CHECKS)
            (root / 'driver.m').write_text(DRIVER)
            (root / 'game').mkdir()
            subprocess.run(['xcrun', 'clang', '-fobjc-arc', str(GAME_WRITER), str(root / 'driver.m'), '-framework', 'Foundation', '-framework', 'Security', '-o', str(root / 'write')], check=True)
            subprocess.run([str(root / 'write'), str(root / 'game')], check=True)
            subprocess.run(['swiftc', '-parse-as-library', '-Onone', '-o', str(root / 'check'), str(root / 'Checks.swift'), *map(str, sorted(SHARED.glob('*.swift')))], check=True)
            # asserts are on without -O
            result = subprocess.run([str(root / 'check'), str(root), str(root / 'game')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)


if __name__ == '__main__':
    unittest.main()
