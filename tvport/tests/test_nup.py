"""A Switch 2 game in a NUP container: found, identified and needing no prod.keys."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import backend

NAME = 'The Legend of Zelda Ocarina of Time [0400486024DEC000][v131072].nup'


class NupGame(unittest.TestCase):
    def folder(self, *files):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        for name in files:
            (Path(tmp.name) / name).write_bytes(b'NUP\x01 not a real container')
        return Path(tmp.name).resolve()

    def game(self, folder):
        data = folder.parent / (folder.name + '-data'); data.mkdir()
        with patch.object(backend, 'DATA', data), patch.dict(backend.os.environ, {'TVPORT_DEFAULT_BUILD_FOLDER': ''}):
            return backend.Game(folder)

    def test_project_gets_a_display_name_when_the_nup_has_no_control_name(self):
        # A NUP carries no control.nacp name; build_ipa.sh then stops with "no game name ... set DM_DISPLAY_NAME" (Ocarina, 2026-11-08)
        from types import SimpleNamespace
        folder = self.folder(NAME)
        (folder / '0400486024DEC000_build' / 'extract' / 'v131072').mkdir(parents=True)
        game = self.game(folder)
        args = SimpleNamespace(fps=False, mode='handheld', texture_cap=256, players='', render_scale=1, no_thermal_cap=False, fps_target=0, swap_ab_xy=False, swap_ab=None, swap_xy=None, pso_mtl4=False, art=None, shelf_art=None)
        with patch.object(backend, 'restore_tables'), patch.object(backend, 'profile_env', return_value={}), patch.object(backend, 'write_env', return_value=folder / 'env.txt'), \
                patch.object(backend, 'artwork_env', return_value={}), patch.object(backend, 'stream') as stream, \
                patch.object(backend.Game, 'package', 'v131072'), patch.object(backend.Game, 'shaders', None), patch.object(backend.Game, 'icon', None):
            backend.generate_project(game, args, 'TEAM', 'test.game', sys.executable)
        self.assertEqual(stream.call_args.kwargs['env'].get('DM_DISPLAY_NAME'), game.name())
        self.assertTrue(game.name())

    def test_nup_is_a_source_and_keyless(self):
        game = self.game(self.folder(NAME, 'extras.rar', 'notes.zip'))
        self.assertEqual(game.sources, [NAME])
        self.assertTrue(game.keyless)
        self.assertEqual(game.artwork_title_id, '0400486024DEC000')

    def test_nsp_beside_nup_still_needs_keys(self):
        game = self.game(self.folder(NAME, 'Other.nsp'))
        self.assertFalse(game.keyless)

    def test_file_name_gives_title_id_and_version_when_the_container_is_unreadable(self):
        game = self.game(self.folder(NAME))
        info = game.nup_info()
        self.assertEqual((info['title_id'], info['version']), ('0400486024DEC000', 131072))
        self.assertFalse(info['from_container'])
        self.assertIn('Could not read the NUP', info['error'])

    def test_no_nup_no_info(self):
        self.assertEqual(self.game(self.folder('Game.nsp')).nup_info(), {})

    def test_inspect_does_not_crash_and_reports_it(self):
        folder = self.folder(NAME)
        out = []
        with patch.object(backend, 'DATA', folder.parent / 'd'), patch.object(backend, 'known_team', return_value=''), patch('builtins.print', lambda s: out.append(s)):
            backend.cmd_inspect(type('A', (), {'folder': folder})())
        info = json.loads(out[0])
        self.assertEqual((info['title_id'], info['artwork_title_id'], info['keyless'], info['sources']), ('', '0400486024DEC000', True, [NAME]))
        self.assertFalse(info['built'])

    def test_check_addons_skips_a_nup(self):
        game = self.game(self.folder(NAME))
        with patch.object(backend, 'emit'), patch.object(backend, 'run') as run:
            answer = backend.check_addons(game, [])
        run.assert_not_called()
        self.assertEqual(answer['addons'], [])
        self.assertEqual(answer['title_id'], '0400486024DEC000')

    def test_prepare_passes_no_keys_for_a_nup(self):
        game = self.game(self.folder(NAME))
        seen = []
        def fake_run(command, *a, **k):
            seen.append([str(c) for c in command]); raise backend.Failure('stop here')
        with patch.object(backend, 'emit'), patch.object(backend, 'stage'), patch.object(backend, 'find_keys', return_value=None), patch.object(backend, 'stream', side_effect=fake_run), patch.object(backend, 'run', side_effect=fake_run):
            with self.assertRaises(backend.Failure) as caught:
                backend.prepare_game(game, None, 'TEAM', 'python3')
        self.assertNotIn('prod.keys', str(caught.exception))
        if seen:
            self.assertNotIn('-k', seen[0])

    def test_nsp_without_keys_explains_nup(self):
        game = self.game(self.folder('Game.nsp'))
        with patch.object(backend, 'emit'), patch.object(backend, 'stage'), patch.object(backend, 'find_keys', return_value=None):
            with self.assertRaisesRegex(backend.Failure, 'Switch 2 game packed as a .nup needs none'):
                backend.prepare_game(game, None, 'TEAM', 'python3')


if __name__ == '__main__':
    unittest.main()
