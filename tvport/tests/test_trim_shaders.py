"""The Trim shaders Advanced option (docs/reference/tv-size.md, "Cut 2 as built"): off by default, the shader_trim.py run in the build with the TV's and the profile's lists, its reuse and
fallbacks, and the trimmed library reaching build_ipa.sh through MSL_IOS."""
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import backend  # noqa: E402

CHAIN = 'abc123def456'
TITLE = '0400486024DEC000'


class Choice(unittest.TestCase):
    def test_the_build_command_takes_the_choice_and_it_is_off_by_default(self):
        for argv, expected in ((['--trim-shaders', 'on'], 'on'), (['--trim-shaders', 'off'], 'off'), ([], 'off')):
            with patch.object(sys, 'argv', ['backend.py', 'build', '/x'] + argv), patch.object(backend, 'cmd_build') as build, patch.object(backend, 'BUNDLED', False):
                backend.main()
            self.assertEqual(build.call_args.args[0].trim_shaders, expected)


class Run(unittest.TestCase):
    """trim_shaders against a build folder with a fake library and a fake tool run"""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.build = self.root / f'{TITLE}_build'
        (self.build / 'shader/ios').mkdir(parents=True)
        (self.build / f'shader/ios/b-{CHAIN}.img').write_bytes(b'c' * 5000)
        (self.build / backend.SHADER_LIST).write_text('S\tkey_b\t0\n')
        profile = self.build / f'profile/{TITLE}'; profile.mkdir(parents=True)
        (profile / 'shader_map.tsv').write_text('package\tindex\tstage\tdm_ctl_sha16\tsource\n')
        (profile / 'pso_manifest.tsv').write_text('S\tother_b\t1\n')
        (profile / 'shader_seen.tsv').write_text('0123456789abcdef\tpixel\n')
        self.repo = self.root / 'repo'; tool = self.repo / 'dm/gfx/tools/shader_trim.py'; tool.parent.mkdir(parents=True); tool.write_text('# tool')
        self.game = SimpleNamespace(build=self.build, title_id=TITLE, profile_root=self.build / 'profile', shaders=self.build / 'shader/ios')
        self.calls = []

    def run_trim(self, choice='on', fail=None, make=True, game=None):
        def fake_stream(argv, **kwargs):
            self.calls.append([str(a) for a in argv])
            if fail:
                raise backend.Failure(fail)
            if make:
                out = Path(str(argv[argv.index('--out') + 1])); out.mkdir(parents=True)
                (out / f'b-{CHAIN}.img').write_bytes(b't' * 1000)
                (out / 'trim_report.json').write_text(json.dumps({'packed': 3, 'shaders': 5, 'image_bytes': 1000, 'library_bytes': 5000}))
        out = io.StringIO()
        with patch.object(backend, 'REPO', self.repo), patch.object(backend, 'chain', return_value=CHAIN), patch.object(backend, 'stream', side_effect=fake_stream), redirect_stdout(out):
            result = backend.trim_shaders(game or self.game, SimpleNamespace(trim_shaders=choice), 'python3')
        return result, out.getvalue()

    def test_on_trims_the_library_with_the_tv_and_profile_lists(self):
        result, text = self.run_trim()
        self.assertEqual(result, self.build / backend.TRIM_DIR)
        split = self.calls[0]
        self.assertEqual(split[:3], ['python3', '-I', str(self.repo / 'dm/gfx/tools/shader_trim.py')]); self.assertEqual(split[3], 'split')
        self.assertEqual(split[split.index('--lib') + 1], str(self.build / f'shader/ios/b-{CHAIN}'))
        self.assertEqual(split[split.index('--map') + 1], str(self.build / f'profile/{TITLE}/shader_map.tsv'))
        used = [split[i + 1] for i, a in enumerate(split) if a == '--used']
        self.assertEqual(used, [str(self.build / backend.SHADER_LIST), str(self.build / f'profile/{TITLE}/pso_manifest.tsv'), str(self.build / f'profile/{TITLE}/shader_seen.tsv')])
        self.assertIn('3 of 5 shaders packed', text)

    def test_off_and_no_choice_do_nothing(self):
        for choice in ('off', None):
            result, _ = self.run_trim(choice=choice)
            self.assertIsNone(result); self.assertEqual(self.calls, [])

    def test_a_failed_tool_keeps_the_whole_library_with_one_line(self):
        result, text = self.run_trim(fail='Python 3.14 needed')
        self.assertIsNone(result); self.assertFalse((self.build / backend.TRIM_DIR).exists())
        self.assertEqual(len([line for line in text.splitlines() if 'not trimmed' in line]), 1); self.assertIn('Python 3.14 needed', text)

    def test_a_tool_that_leaves_no_library_is_not_trusted(self):
        result, _ = self.run_trim(make=False)
        self.assertIsNone(result); self.assertFalse((self.build / backend.TRIM_DIR / 'trim.key').exists())

    def test_without_a_library_or_any_list(self):
        (self.build / f'shader/ios/b-{CHAIN}.img').unlink()
        result, text = self.run_trim(game=SimpleNamespace(build=self.build, title_id=TITLE, profile_root=self.build / 'profile', shaders=None))
        self.assertIsNone(result); self.assertIn('no shader library', text)
        (self.build / f'shader/ios/b-{CHAIN}.img').write_bytes(b'c')
        for p in (self.build / backend.SHADER_LIST, self.build / f'profile/{TITLE}/pso_manifest.tsv', self.build / f'profile/{TITLE}/shader_seen.tsv'): p.unlink()
        result, text = self.run_trim()
        self.assertIsNone(result); self.assertIn('no list', text)

    def test_an_unchanged_build_reuses_the_trimmed_library_and_a_new_tv_list_makes_it_again(self):
        first, _ = self.run_trim()
        self.calls.clear()
        again, text = self.run_trim()
        self.assertEqual(again, first); self.assertEqual(self.calls, []); self.assertIn('still fits', text)
        (self.build / backend.SHADER_LIST).write_text('S\tkey_b\t0\nS\tnew_b\t1\n')   # the Apple TV recorded more
        self.run_trim()
        self.assertEqual(len(self.calls), 1)


class Project(unittest.TestCase):
    def test_the_project_takes_the_trimmed_library(self):
        args = SimpleNamespace(fps=False, mode='handheld', texture_cap=512, players='', render_scale=1, no_thermal_cap=False, fps_target=0, swap_ab_xy=False, swap_ab=None, swap_xy=None,
                               art=None, art_scale=0, art_x=0, art_y=0, shelf_art=None, shelf_scale=0, shelf_x=0, shelf_y=0, pso_mtl4=False, extra_env=[])
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / '0100000000010000_build').mkdir()
            game = backend.Game(Path(folder))
            seen = []
            for trimmed in (None, Path(folder) / 'trim'):
                args.shader_trim_dir = trimmed
                with patch.object(backend, 'restore_tables'), patch.object(backend, 'stream') as stream, patch.object(backend.Game, 'shaders', Path('/plain/shader/ios')), \
                     patch.object(backend, 'write_env', return_value=Path(folder) / 'env.txt'), patch.object(backend, 'store_artwork', return_value=None), redirect_stdout(io.StringIO()):
                    backend.generate_project(game, args, 'TEAM', 'test.game', sys.executable)
                seen.append(stream.call_args.kwargs['env']['MSL_IOS'])
        self.assertEqual(seen, ['/plain/shader/ios', str(Path(folder) / 'trim')])


class Build(unittest.TestCase):
    def test_cmd_build_trims_after_the_tv_list_is_merged_and_hands_the_folder_to_the_project(self):
        args = SimpleNamespace(folder='/g', team='T', keys=None, device='dev', texture_cap=512, astc='off', texture_once='auto', compress_data='off', icloud=False, art=None, mode='handheld',
                               render_scale=1, trim_shaders='on', gpu='g14p')   # named: no paired-device lookup
        game = SimpleNamespace(build=Path('/b'), romfs=Path('/r'), app=Path('/a'), prepared=True, addons=[], input_signature=lambda: 's', state=lambda: {'source_signature': 's'},
                               bundle_id=lambda team: 'b', save_state=lambda **kw: None)
        for trimmed in (None, Path('/b/tvport-shadertrim')):
            order = []
            with patch.object(backend, 'Game', return_value=game), patch.object(backend, 'known_team', return_value='T'), patch.object(backend, 'relocate_build', return_value=game), \
                 patch.object(backend, 'BUNDLED', False), patch.object(backend, 'engine_python', return_value='python3'), patch.object(backend, 'one_build_at_a_time'), \
                 patch.object(backend, 'engine_change', return_value=None), patch.object(backend, 'astc_blocks', return_value=(0, None)), patch.object(backend, 'astc_format_blocks', return_value=None), \
                 patch.object(backend, 'remember_shaders', side_effect=lambda *a: order.append('remember')), patch.object(backend, 'backup_saves', return_value={'state': 'none', 'files': 0}), \
                 patch.object(backend, 'generate_project') as generate, patch.object(backend, 'bundle_shaders', side_effect=lambda *a: order.append('bundle')), \
                 patch.object(backend, 'prewarm_pipelines', side_effect=lambda *a: order.append('prewarm')) as prewarm, patch.object(backend, 'compile_app', side_effect=lambda *a: order.append('compile')), \
                 patch.object(backend, 'install'), patch.object(backend, 'restore_saves', return_value=0), patch.object(backend, 'provisioning', return_value={}), \
                 patch.object(backend, 'trim_shaders', side_effect=lambda *a: order.append('trim') or trimmed) as trim, redirect_stdout(io.StringIO()):
                backend.cmd_build(args)
            self.assertEqual(generate.call_args.args[1].shader_trim_dir, trimmed)
            self.assertEqual(trim.call_args.args[2], 'python3')
            self.assertEqual(order, ['remember', 'trim', 'bundle', 'prewarm', 'compile'])   # the Apple TV's list is merged before the lists are read; the prewarm pipelines are made from the app's whole list
            self.assertEqual(prewarm.call_args.args[2].shader_trim_dir, trimmed)


if __name__ == '__main__':
    unittest.main()
