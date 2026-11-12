"""TVPort's side of SwitchTV (the launcher is the brad-n/SwitchTV submodule at tvport/switchtv, with its own tests): the library as SwitchTV's games file, the catalogue made through its
command line tool, and when the app on the Apple TV is refreshed."""
import io
import json
import os
import shutil
import struct
import sys
import tempfile
import unittest
import zlib
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import backend  # noqa: E402

KART, WONDER, UNBUILT = '0100152000022000', '010015100B514000', '0100AAAA00000000'
GAME_BANNER = 'https://img-eshop.cdn.nintendo.net/i/game.jpg'
TITLEDB = {
    '1': {'id': KART, 'name': 'Mario Kart™ 8 Deluxe', 'publisher': 'Nintendo', 'releaseDate': 20170428, 'numberOfPlayers': 4, 'category': ['Racing', 'Multiplayer'],
          'bannerUrl': 'https://img-eshop.cdn.nintendo.net/i/kart.jpg'},
    '2': {'id': WONDER, 'name': 'Wonder', 'publisher': 'Nintendo', 'releaseDate': 20231020, 'category': ['Platformer'], 'bannerUrl': GAME_BANNER},
}
LIBRARY = [
    {'name': 'Mario Kart 8 Deluxe', 'titleID': KART, 'built': True, 'folder': '/nowhere/kart'},
    {'name': 'Wonder', 'titleID': WONDER.lower(), 'built': True, 'folder': '/nowhere/wonder'},
    {'name': 'Not built', 'titleID': UNBUILT, 'built': False},
    {'name': 'No title ID', 'built': True},
]


def png(path: Path) -> None:
    def chunk(kind, data):
        body = kind + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body))
    rows = b''.join(b'\x00' + b'\x80\x40\xc0' * 16 for _ in range(9))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 16, 9, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.data, self.cache = self.root / 'data', self.root / 'cache'
        (self.data / 'artwork').mkdir(parents=True)
        png(self.data / 'artwork' / f'{KART}.jpg')   # a PNG under the .jpg name: the tool converts whatever it is given
        (self.data / 'artwork/sources.json').write_text(json.dumps({WONDER: GAME_BANNER}))
        self.cache.mkdir()
        (self.cache / 'US.en.json').write_text(json.dumps(TITLEDB))
        (self.cache / 'banners').mkdir()
        png(self.cache / 'banners' / f'{WONDER}.jpg')

    def tearDown(self):
        self.temp.cleanup()


class GamesFileTests(Fixture):
    def test_only_built_games_with_a_title_id_and_what_tvport_knows_about_them(self):
        games = backend.switchtv_games(LIBRARY, 'TEAM123456', self.data)
        self.assertEqual([g['titleID'] for g in games], [KART, WONDER])
        kart, wonder = games
        self.assertEqual(kart['artwork'], str(self.data / 'artwork' / f'{KART}.jpg'))
        self.assertNotIn('artworkSource', kart)
        self.assertEqual(wonder['artworkSource'], GAME_BANNER)
        self.assertNotIn('artwork', wonder)   # no art of its own: SwitchTV takes the shop banner
        self.assertEqual(wonder['bundleID'], 'dev.tvport.team123456.g010015100b514000')   # the standard bundle ID when the build folder is not at hand

    def test_the_tool_is_found_in_the_submodule_and_a_missing_one_says_how_to_get_it(self):
        self.assertTrue(backend.switchtv_tool().is_file())
        with patch.object(backend, 'REPO', self.root), self.assertRaisesRegex(backend.Failure, 'git submodule update --init'):
            backend.switchtv_tool()


@unittest.skipUnless(sys.platform == 'darwin', 'sips is macOS')
class CatalogThroughTheToolTests(Fixture):
    def test_prepare_makes_the_catalogue_and_a_fingerprint_that_follows_the_library(self):
        (self.data / 'library.json').write_text(json.dumps(LIBRARY))
        env = {'TVPORT_SWITCHTV_CACHE': str(self.cache)}
        with patch.dict(os.environ, env), patch.object(backend, 'DATA', self.data), redirect_stdout(io.StringIO()):
            work, catalog, first = backend.prepare_switchtv('TEAM123456')
            self.assertEqual([g['titleID'] for g in catalog['games']], [WONDER, KART])
            self.assertEqual(catalog['games'][1]['publisher'], 'Nintendo')
            self.assertTrue((work / catalog['games'][1]['card']).is_file())
            self.assertEqual(backend.prepare_switchtv('TEAM123456')[2], first)   # same library, same fingerprint
            (self.data / 'library.json').write_text(json.dumps(LIBRARY[:1]))
            self.assertNotEqual(backend.prepare_switchtv('TEAM123456')[2], first)


class SyncTests(Fixture):
    def run_sync(self, fingerprint, **kwargs):
        calls = []
        prepare = lambda team: (self.root / 'work', {'games': [1, 2]}, fingerprint)
        compile_app = lambda work, device, team: calls.append('build') or self.root / 'SwitchTV.app'
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
