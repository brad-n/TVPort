"""The Trim shaders Advanced option (docs/shader_trimming.md): the per-game choice, the shader_trim.py run in the build, its fallbacks, and the trimmed image and map reaching build_ipa.sh and the project."""
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

CHAIN = 'abc123def456'


class Choice(unittest.TestCase):
    def test_automatic_needs_a_list_of_a_thousand_shaders(self):
        enabled = backend.trim_enabled
        for choice, used, expected in (('auto', 999, False), ('auto', 1000, True), (None, 12098, True), (None, 0, False), ('on', 0, True), ('on', 5, True), ('off', 12098, False)):
            self.assertEqual(enabled(choice, used), expected, (choice, used))

    def test_the_build_command_takes_the_choice(self):
        for argv, expected in ((['--trim-shaders', 'off'], 'off'), (['--trim-shaders', 'on'], 'on'), ([], 'auto')):
            with patch.object(sys, 'argv', ['backend.py', 'build', '/x'] + argv), patch.object(backend, 'cmd_build') as build, patch.object(backend, 'BUNDLED', False):
                backend.main()
            self.assertEqual(build.call_args.args[0].trim_shaders, expected)


class Run(unittest.TestCase):
    """trim_shaders against a build folder with fake inputs and a fake tool run"""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.build = self.root / 'game_build'
        (self.build / 'shader/ios').mkdir(parents=True); (self.build / 'shader/cache').mkdir(parents=True)
        (self.build / f'shader/ios/b-{CHAIN}.img').write_bytes(b'c' * 5000)
        (self.build / f'shader/cache/b-{CHAIN}.img').write_bytes(b's' * 900)
        (self.build / backend.SHADER_LIST).write_text('S\tkey_b\t0\n')
        profile = self.build / 'profile/0100152000022000'; profile.mkdir(parents=True)
        (profile / 'shader_map.tsv').write_text('package\tindex\tstage\tdm_ctl_sha16\tsource\n')
        (profile / 'pso_manifest.tsv').write_text('S\tother_b\t1\n')
        self.repo = self.root / 'repo'; tool = self.repo / 'dm/gfx/tools/shader_trim.py'; tool.parent.mkdir(parents=True); tool.write_text('# tool')
        self.game = SimpleNamespace(build=self.build, title_id='0100152000022000', profile_root=self.build / 'profile')
        self.calls = []

    def run_trim(self, choice='auto', used=12000, fail=None, make=True, tool=True, game=None):
        if not tool:
            (self.repo / 'dm/gfx/tools/shader_trim.py').unlink()

        def fake_run(argv, **kwargs):
            self.calls.append([str(a) for a in argv])
            return SimpleNamespace(stdout=f'{used}\n', returncode=0)

        def fake_stream(argv, **kwargs):
            self.calls.append([str(a) for a in argv])
            if fail:
                raise backend.Failure(fail)
            if make:
                out = Path(str(argv[argv.index('--out') + 1])); out.mkdir(parents=True)
                (out / f'b-{CHAIN}.img').write_bytes(b't' * 1000); (out / 'shader_map.tsv').write_text('trimmed map\n')
        out = io.StringIO()
        with patch.object(backend, 'REPO', self.repo), patch.object(backend, 'chain', return_value=CHAIN), patch.object(backend, 'run', side_effect=fake_run), \
             patch.object(backend, 'stream', side_effect=fake_stream), redirect_stdout(out):
            result = backend.trim_shaders(game or self.game, SimpleNamespace(trim_shaders=choice), 'python3')
        return result, out.getvalue()

    def test_a_game_with_a_long_list_is_trimmed_from_the_lists_the_images_and_the_profile(self):
        result, text = self.run_trim()
        self.assertEqual(result, self.build / backend.TRIM_DIR)
        split = next(c for c in self.calls if 'split' in c)
        self.assertEqual(split[:2], ['python3', '-I']); self.assertTrue(split[2].endswith('dm/gfx/tools/shader_trim.py'))
        self.assertEqual(split[split.index('--compiled') + 1], str(self.build / f'shader/ios/b-{CHAIN}.img'))
        self.assertEqual(split[split.index('--sources') + 1], str(self.build / f'shader/cache/b-{CHAIN}.img'))
        self.assertEqual(split[split.index('--map') + 1], str(self.build / 'profile/0100152000022000/shader_map.tsv'))
        used = [split[i + 1] for i, a in enumerate(split) if a == '--used']
        self.assertEqual(used, [str(self.build / backend.SHADER_LIST), str(self.build / 'profile/0100152000022000/pso_manifest.tsv')])   # the TV's list and the profile's, both
        self.assertIn('go in compiled', text)

    def test_automatic_below_the_threshold_and_off_leave_the_full_set(self):
        result, text = self.run_trim(used=999)
        self.assertIsNone(result); self.assertFalse(any('split' in c for c in self.calls)); self.assertIn('needs 1000', text)
        self.calls.clear()
        result, _ = self.run_trim(choice='off')
        self.assertIsNone(result); self.assertEqual(self.calls, [])   # Off does not even count

    def test_on_trims_a_short_list(self):
        result, _ = self.run_trim(choice='on', used=3)
        self.assertEqual(result, self.build / backend.TRIM_DIR)

    def test_a_failed_tool_builds_the_full_set_with_one_warning(self):
        result, text = self.run_trim(fail='zstd missing')
        self.assertIsNone(result); self.assertFalse((self.build / backend.TRIM_DIR).exists())
        self.assertEqual(len([line for line in text.splitlines() if 'did not work' in line]), 1); self.assertIn('zstd missing', text)

    def test_a_tool_that_leaves_no_image_is_not_trusted_for_the_next_build(self):
        self.run_trim(make=False)
        self.assertFalse((self.build / backend.TRIM_DIR / 'trim.key').exists())

    def test_missing_mac_shader_cache_or_tool_falls_back(self):
        (self.build / f'shader/cache/b-{CHAIN}.img').unlink()
        result, text = self.run_trim(choice='on')
        self.assertIsNone(result); self.assertIn('needs the Mac shader build', text)
        self.assertIsNone(self.run_trim(choice='auto', tool=False)[0])

    def test_an_unchanged_build_reuses_the_trimmed_image(self):
        first, _ = self.run_trim()
        self.calls.clear()
        again, text = self.run_trim()
        self.assertEqual(again, first); self.assertFalse(any('split' in c for c in self.calls)); self.assertIn('still fits', text)
        (self.build / backend.SHADER_LIST).write_text('S\tkey_b\t0\nS\tnew_b\t1\n')   # the Apple TV recorded more: the list changed
        self.calls.clear(); self.run_trim()
        self.assertTrue(any('split' in c for c in self.calls))


class Project(unittest.TestCase):
    def test_the_project_is_built_from_the_trimmed_image_and_gets_its_map(self):
        args = SimpleNamespace(fps=False, mode='handheld', texture_cap=512, players='', render_scale=1, no_thermal_cap=False, fps_target=0, swap_ab_xy=False, swap_ab=None, swap_xy=None,
                               art=None, art_scale=0, art_x=0, art_y=0, shelf_art=None, shelf_scale=0, shelf_x=0, shelf_y=0, pso_mtl4=False, extra_env=[])
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / '0100000000010000_build').mkdir()
            game = backend.Game(Path(folder))
            trim = Path(folder) / 'trim'; trim.mkdir(); (trim / 'shader_map.tsv').write_text('trimmed map\n')
            project = game.build / 'tvport-xcode/Gen/dm'; project.mkdir(parents=True); (project / 'shader_map.tsv').write_text('full map\n')
            seen = []
            for trimmed in (None, trim):
                args.shader_trim_dir = trimmed
                with patch.object(backend, 'restore_tables'), patch.object(backend, 'stream') as stream, patch.object(backend.Game, 'shaders', Path('/plain/shader/ios')):
                    backend.generate_project(game, args, 'TEAM', 'test.game', sys.executable)
                seen.append((stream.call_args.kwargs['env']['MSL_IOS'], (project / 'shader_map.tsv').read_text()))
        self.assertEqual(seen, [('/plain/shader/ios', 'full map\n'), (str(trim), 'trimmed map\n')])


class Build(unittest.TestCase):
    def test_cmd_build_hands_the_trimmed_folder_to_the_project(self):
        pack = Path('/x/pack')
        args = SimpleNamespace(folder='/g', team='T', keys=None, device='dev', texture_cap=512, astc='off', astc_block=4, texture_once='auto', icloud=False, art=None, mode='handheld', render_scale=1, trim_shaders='auto')
        game = SimpleNamespace(build=Path('/b'), romfs=Path('/r'), app=Path('/a'), prepared=True, addons=[], input_signature=lambda: 's', state=lambda: {'source_signature': 's'}, bundle_id=lambda team: 'b', save_state=lambda **kw: None)
        for trimmed in (None, Path('/b/tvport-shadertrim')):
            with patch.object(backend, 'Game', return_value=game), patch.object(backend, 'known_team', return_value='T'), patch.object(backend, 'relocate_build', return_value=game), \
                 patch.object(backend, 'BUNDLED', False), patch.object(backend, 'engine_python', return_value='python3'), patch.object(backend, 'one_build_at_a_time'), \
                 patch.object(backend, 'prebuild_astc', return_value=pack), patch.object(backend, 'remember_shaders') as remember, patch.object(backend, 'backup_saves', return_value={'state': 'none', 'files': 0}), \
                 patch.object(backend, 'generate_project') as generate, patch.object(backend, 'bundle_shaders'), patch.object(backend, 'compile_app'), patch.object(backend, 'install'), \
                 patch.object(backend, 'restore_saves', return_value=0), patch.object(backend, 'provisioning', return_value={}), patch.object(backend, 'store_textures_once', return_value=None), \
                 patch.object(backend, 'trim_shaders', return_value=trimmed) as trim, redirect_stdout(io.StringIO()):
                backend.cmd_build(args)
            self.assertEqual(generate.call_args.args[1].shader_trim_dir, trimmed)
            self.assertEqual(trim.call_args.args[2], 'python3')
            # the Apple TV's list is merged before the lists are read
            self.assertTrue(remember.called)


if __name__ == '__main__':
    unittest.main()
