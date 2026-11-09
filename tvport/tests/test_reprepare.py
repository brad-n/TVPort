"""A prepared game is rewritten again when the engine's code patches changed since (patched_<version>/build_src.sha256), not when they match."""
import hashlib
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import backend  # noqa: E402

TID = '0400486024DEC000'


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class RePrepare(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.repo = root / 'repo'
        (self.repo / 'dm/tools').mkdir(parents=True)
        (self.repo / f'dm/games/{TID}').mkdir(parents=True)
        (self.repo / 'dm/games/0100OTHER').mkdir(parents=True)
        self.files = {'dm/tools/patch_nso.py': b'rewriter', f'dm/games/{TID}/patches.py': b'mine', 'dm/games/0100OTHER/patches.py': b'theirs', f'dm/games/{TID}/game.tsv': b'profile'}
        for name, data in self.files.items():
            (self.repo / name).write_bytes(data)
        self.folder = root / 'game'
        self.build = self.folder / f'{TID}_build'
        (self.build / 'patched_v1').mkdir(parents=True)
        self.record = self.build / 'patched_v1/build_src.sha256'
        self.record.write_text(''.join(f'{sha(self.files[n])}  {rel}\n' for n, rel in (('dm/tools/patch_nso.py', 'patch_nso.py'), (f'dm/games/{TID}/patches.py', f'../games/{TID}/patches.py'), ('dm/games/0100OTHER/patches.py', '../games/0100OTHER/patches.py'))))
        self.game = SimpleNamespace(build=self.build, package='v1', title_id=TID, state=lambda: {})
        patcher = patch.object(backend, 'REPO', self.repo); patcher.start(); self.addCleanup(patcher.stop)

    def test_matching_record_is_current(self):
        self.assertIsNone(backend.engine_change(self.game))

    def test_changed_patch_file_triggers(self):
        (self.repo / f'dm/games/{TID}/patches.py').write_bytes(b'new')
        self.assertIn('patches.py', backend.engine_change(self.game))

    def test_changed_rewriter_triggers(self):
        (self.repo / 'dm/tools/patch_nso.py').write_bytes(b'new rewriter')
        self.assertIn('patch_nso.py', backend.engine_change(self.game))

    def test_another_games_patches_do_not(self):
        (self.repo / 'dm/games/0100OTHER/patches.py').write_bytes(b'changed')
        self.assertIsNone(backend.engine_change(self.game))

    def test_missing_recorded_file_triggers(self):
        (self.repo / f'dm/games/{TID}/patches.py').unlink()
        self.assertIn('gone', backend.engine_change(self.game))

    def test_missing_record_triggers(self):
        self.record.unlink()
        self.assertIn('missing', backend.engine_change(self.game))

    def test_profile_change_triggers_only_when_recorded(self):
        self.assertIsNone(backend.engine_change(self.game))   # a game prepared before profile_signature existed: nothing to compare
        recorded = backend.profile_signature(self.game)
        self.game.state = lambda: {'profile_signature': recorded}
        self.assertIsNone(backend.engine_change(self.game))
        (self.repo / f'dm/games/{TID}/game.tsv').write_bytes(b'edited')
        self.assertIn('profile', backend.engine_change(self.game))

    def test_unprepared_game_is_left_to_the_normal_path(self):
        self.assertIsNone(backend.engine_change(SimpleNamespace(build=None, package=None, title_id='', state=lambda: {})))


class BuildDecision(unittest.TestCase):
    def run_build(self, game, keys='k'):
        args = SimpleNamespace(folder='/x', team='T', keys=keys, device=None, texture_cap=512, astc='off', astc_block=4, texture_once='off', compress_data='off', icloud=False, art=None, mode='handheld', render_scale=1, extra_env=None)
        out = io.StringIO()
        with patch.object(backend, 'Game', return_value=game), patch.object(backend, 'known_team', return_value='T'), patch.object(backend, 'relocate_build', return_value=game), \
             patch.object(backend, 'BUNDLED', False), patch.object(backend, 'engine_python', return_value='python3'), patch.object(backend, 'one_build_at_a_time'), \
             patch.object(backend, 'compress_enabled', return_value=False), patch.object(backend, 'compress_game_data', return_value=None), patch.object(backend, 'generate_project'), \
             patch.object(backend, 'bundle_shaders'), patch.object(backend, 'compile_app'), patch.object(backend, 'provisioning', return_value={}), \
             patch.object(backend, 'find_keys', return_value=None), patch.object(backend, 'prepare_game', side_effect=lambda g, *a: g) as prepare, \
             patch.object(backend, 'emit') as emit, redirect_stdout(out):
            backend.cmd_build(args)
        return prepare, [c.kwargs.get('line', '') for c in emit.call_args_list if c.args[:1] == ('log',)]

    def game(self, state, why):
        return SimpleNamespace(build=Path('/b'), romfs=None, app=None, prepared=True, addons=[], input_signature=lambda: 's', state=lambda: state, bundle_id=lambda team: 'b', save_state=lambda **kw: None, package='v1', title_id=TID), why

    def go(self, state, why, **kw):
        game, why = self.game(state, why)
        with patch.object(backend, 'engine_change', return_value=why):
            return self.run_build(game, **kw)

    def test_current_game_is_not_prepared_again(self):
        prepare, _ = self.go({'source_signature': 's'}, None)
        prepare.assert_not_called()

    def test_changed_engine_prepares_again_and_says_so(self):
        prepare, log = self.go({'source_signature': 's'}, 'patches.py changed', keys=__file__)
        prepare.assert_called_once()
        self.assertTrue(any("engine's patches for this game changed" in l for l in log))

    def test_game_prepared_before_this_change_with_no_state_is_left_alone(self):
        prepare, _ = self.go({}, None)
        prepare.assert_not_called()

    def test_source_signature_change_still_prepares(self):
        prepare, _ = self.go({'source_signature': 'old'}, None)
        prepare.assert_called_once()

    def test_changed_engine_without_keys_goes_on_with_a_note(self):
        prepare, log = self.go({'source_signature': 's'}, 'x changed', keys=None)
        prepare.assert_not_called()
        self.assertTrue(any('prod.keys was not found' in l for l in log))


if __name__ == '__main__':
    unittest.main()
