"""SwitchTV's catalogue: made from a fixture library and a titledb snippet, with no network and no Xcode."""
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import backend  # noqa: E402
import switchtv_catalog as sc  # noqa: E402

KART, WONDER, UNBUILT = '0100152000022000', '010015100B514000', '0100AAAA00000000'
GAME_BANNER = 'https://img-eshop.cdn.nintendo.net/i/game.jpg'
TITLEDB = {
    '1': {'id': KART, 'name': 'Mario Kart™ 8 Deluxe', 'publisher': 'Nintendo', 'releaseDate': 20170428, 'numberOfPlayers': 4, 'category': ['Racing', 'Multiplayer', 'Other'],
          'description': 'Race.', 'intro': 'Race anywhere', 'bannerUrl': 'https://img-eshop.cdn.nintendo.net/i/kart.jpg', 'screenshots': ['https://img-eshop.cdn.nintendo.net/i/s1.jpg', 'ftp://bad']},
    '2': {'id': WONDER, 'name': 'Wonder', 'publisher': 'Nintendo', 'releaseDate': 20231020, 'numberOfPlayers': 4, 'category': ['Platformer', 'Action'], 'bannerUrl': GAME_BANNER, 'screenshots': []},
    '3': {'id': WONDER, 'name': 'Wonder Switch 2 Edition', 'publisher': 'Nintendo', 'releaseDate': 20260326, 'bannerUrl': 'https://img-eshop.cdn.nintendo.net/i/s2.jpg'},
}
LIBRARY = [
    {'name': 'Mario Kart 8 Deluxe', 'titleID': KART, 'built': True, 'folder': '/nowhere/kart'},
    {'name': 'Wonder', 'titleID': WONDER, 'built': True, 'folder': '/nowhere/wonder'},
    {'name': 'Not built', 'titleID': UNBUILT, 'built': False},
    {'name': 'No title ID', 'built': True},
]


def fake_scale(source, destination, longest):
    shutil.copy(source, destination)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.data, self.cache, self.out = self.root / 'data', self.root / 'cache', self.root / 'out'
        (self.data / 'artwork').mkdir(parents=True)
        for title in (KART, WONDER):
            (self.data / 'artwork' / f'{title}.jpg').write_bytes(b'art-' + title.encode())
        (self.data / 'artwork/sources.json').write_text(json.dumps({WONDER: GAME_BANNER}))
        self.cache.mkdir()
        (self.cache / 'US.en.json').write_text(json.dumps(TITLEDB))
        self.fetches = []

    def tearDown(self):
        self.temp.cleanup()

    def fetch(self, url, destination):
        self.fetches.append(url)
        raise OSError('offline')

    def make(self, library=LIBRARY):
        return sc.build_catalog(library, self.data, self.cache, self.out, lambda item: f'bundle.{item["titleID"]}', fetch=self.fetch, scale=fake_scale)


class CatalogTests(Fixture):
    def test_only_built_games_with_a_title_id(self):
        catalog = self.make()
        self.assertEqual([g['titleID'] for g in catalog['games']], [WONDER, KART])
        self.assertEqual({g['name'] for g in catalog['games']}, {'Mario Kart 8 Deluxe', 'Wonder'})

    def test_fields_come_from_titledb_and_the_library(self):
        game = next(g for g in self.make()['games'] if g['titleID'] == KART)
        self.assertEqual((game['publisher'], game['releaseDate'], game['numberOfPlayers']), ('Nintendo', '2017-04-28', 4))
        self.assertEqual(game['genres'], ['Racing'])   # Multiplayer and Other are not genres
        self.assertEqual(game['scheme'], 'switchtv-0100152000022000')
        self.assertEqual(game['bundleID'], f'bundle.{KART}')
        self.assertEqual(game['screenshots'], ['https://img-eshop.cdn.nintendo.net/i/s1.jpg'])
        self.assertEqual(game['name'], 'Mario Kart 8 Deluxe')   # the library's name, not the shop's with its trademark sign

    def test_the_product_the_artwork_came_from_wins(self):
        game = next(g for g in self.make()['games'] if g['titleID'] == WONDER)
        self.assertEqual(game['releaseDate'], '2023-10-20')   # not the Switch 2 Edition's

    def test_images_are_written_beside_the_catalogue(self):
        catalog = self.make()
        game = catalog['games'][0]
        self.assertTrue((self.out / game['card']).is_file() and (self.out / game['banner']).is_file())
        self.assertEqual(json.loads((self.out / 'catalog.json').read_text()), catalog)

    def test_missing_fields_are_reported(self):
        report = sc.field_report(self.make())
        self.assertEqual(report['Mario Kart 8 Deluxe'], [])
        self.assertEqual(report['Wonder'], ['description', 'screenshots'])

    def test_a_title_database_that_cannot_be_fetched_still_lists_the_games(self):
        (self.cache / 'US.en.json').unlink()
        catalog = self.make()
        self.assertEqual(len(catalog['games']), 2)
        game = catalog['games'][0]
        self.assertIsNone(game['publisher'])
        self.assertTrue(game['banner'])   # the artwork cache still gives the picture

    def test_a_complete_recent_title_database_is_not_fetched_again(self):
        self.make()
        self.assertEqual(self.fetches, [])

    def test_a_game_missing_from_an_old_database_fetches_it_again(self):
        old = {k: v for k, v in TITLEDB.items() if v['id'] != KART}
        (self.cache / 'US.en.json').write_text(json.dumps(old))
        os.utime(self.cache / 'US.en.json', (1, 1))
        self.make()
        self.assertEqual(self.fetches, [sc.TITLEDB_URL])


class FingerprintTests(Fixture):
    def test_same_library_same_fingerprint_whenever_it_is_made(self):
        self.make()
        first = sc.fingerprint(self.out, 'app-1')
        with patch('time.time', return_value=1e9):
            self.make()
        self.assertEqual(sc.fingerprint(self.out, 'app-1'), first)

    def test_changes_with_games_images_and_the_app(self):
        self.make()
        base = sc.fingerprint(self.out, 'app-1')
        self.assertNotEqual(sc.fingerprint(self.out, 'app-2'), base)
        (self.data / 'artwork' / f'{KART}.jpg').write_bytes(b'new art')
        self.make()
        self.assertNotEqual(sc.fingerprint(self.out, 'app-1'), base)
        self.make(LIBRARY[:1])
        self.assertNotEqual(sc.fingerprint(self.out, 'app-1'), base)


class SyncTests(Fixture):
    def run_sync(self, fingerprint, **kwargs):
        calls = []
        prepare = lambda team: (self.root / 'work', {'games': [1, 2]}, fingerprint)
        compile_app = lambda work, device: calls.append('build') or self.root / 'SwitchTV.app'
        install_app = lambda app, device: calls.append('install')
        with patch.dict(os.environ, {'TVPORT_SWITCHTV_CACHE': str(self.cache)}), redirect_stdout(io.StringIO()):
            result = backend.sync_switchtv('TV1', 'TEAM', prepare=prepare, compile_app=compile_app, install_app=install_app, **kwargs)
        return result, calls

    def test_first_sync_builds_and_installs(self):
        self.assertEqual(self.run_sync('aaa'), ('installed', ['build', 'install']))

    def test_unchanged_fingerprint_skips_the_build_and_the_install(self):
        self.run_sync('aaa')
        self.assertEqual(self.run_sync('aaa'), ('unchanged', []))

    def test_changed_fingerprint_installs_again(self):
        self.run_sync('aaa')
        self.assertEqual(self.run_sync('bbb'), ('installed', ['build', 'install']))

    def test_force_installs_even_when_unchanged(self):
        self.run_sync('aaa')
        self.assertEqual(self.run_sync('aaa', force=True), ('installed', ['build', 'install']))

    def test_each_apple_tv_has_its_own_fingerprint(self):
        self.run_sync('aaa')
        state = json.loads((self.cache / 'installed.json').read_text())
        self.assertEqual(state, {'TV1': 'aaa'})


if __name__ == '__main__':
    unittest.main()
