"""Install retries and verification, and the per-game Advanced options reaching the build script, the app's env file and build_ipa.sh."""
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

FAIL_3002 = 'ERROR: Failed to install the app. (com.apple.dt.CoreDeviceError error 3002) Failed to locate coordinated install (IXErrorDomain 6)'


def done(code=0, err='', out=''):
    return SimpleNamespace(returncode=code, stderr=err, stdout=out)


class InstallRetry(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        (root / 'App.app').mkdir(); (root / 'App.app/embedded.mobileprovision').write_text('x')
        (root / 'romfs.img').write_bytes(b'x' * 100)
        self.game = SimpleNamespace(app=root / 'App.app', romfs=root / 'romfs.img')
        for target in ('time.sleep',):
            patcher = patch(target); self.sleep = patcher.start(); self.addCleanup(patcher.stop)

    def logs(self, call):
        out = io.StringIO()
        with redirect_stdout(out):
            call()
        return out.getvalue()

    def test_a_transient_install_failure_is_retried_and_logged(self):
        results = [done(1, FAIL_3002), done(1, FAIL_3002), done(0)]
        with patch.object(backend, 'run', side_effect=results) as run, patch.object(backend, 'installed_files', return_value={'romfs.img': 100}):
            text = self.logs(lambda: backend.install(self.game, 'd', 'b'))
        self.assertEqual(run.call_count, 3)
        self.assertEqual(text.count('Trying again'), 2)
        self.assertIn('already on the Apple TV', text)   # the game data check still runs after the retried install
        self.assertEqual([c.args[0] for c in self.sleep.call_args_list], [5, 15])

    def test_three_failures_stop_without_touching_the_game_data(self):
        with patch.object(backend, 'run', return_value=done(1, FAIL_3002)) as run, patch.object(backend, 'installed_files') as files:
            with self.assertRaises(backend.Failure) as error:
                self.logs(lambda: backend.install(self.game, 'd', 'b'))
        self.assertEqual(run.call_count, 3)
        self.assertIn('3002', str(error.exception))
        files.assert_not_called()

    def test_another_failure_is_not_retried(self):
        with patch.object(backend, 'run', return_value=done(1, 'The application could not be verified')) as run:
            with self.assertRaises(backend.Failure):
                self.logs(lambda: backend.install(self.game, 'd', 'b'))
        self.assertEqual(run.call_count, 1)
        self.sleep.assert_not_called()

    def test_the_game_data_copy_is_retried_and_its_size_verified(self):
        sizes = [{}, {'romfs.img': 100}]
        copies = [backend.Failure('Failed to locate coordinated install: connection lost'), None]

        def fake_stream(argv, **kwargs):
            outcome = copies.pop(0)
            if outcome:
                raise outcome
        with patch.object(backend, 'run', return_value=done(0)), patch.object(backend, 'stream', side_effect=fake_stream) as stream, patch.object(backend, 'installed_files', side_effect=sizes):
            text = self.logs(lambda: backend.install(self.game, 'd', 'b'))
        self.assertEqual(stream.call_count, 2)
        self.assertIn('Sending the game files failed (attempt 1 of 3)', text)
        self.assertIn('match this Mac', text)

    def test_a_size_mismatch_after_the_copy_fails(self):
        with patch.object(backend, 'run', return_value=done(0)), patch.object(backend, 'stream'), patch.object(backend, 'installed_files', side_effect=[{}, {'romfs.img': 40}]):
            with self.assertRaises(backend.Failure) as error:
                self.logs(lambda: backend.install(self.game, 'd', 'b'))
        self.assertIn('40 bytes', str(error.exception))
        self.assertIn('100', str(error.exception))

    def test_a_missing_file_after_the_copy_fails(self):
        with patch.object(backend, 'run', return_value=done(0)), patch.object(backend, 'stream'), patch.object(backend, 'installed_files', side_effect=[{}, {}]):
            with self.assertRaises(backend.Failure) as error:
                self.logs(lambda: backend.install(self.game, 'd', 'b'))
        self.assertIn('no bytes', str(error.exception))


class Advanced(unittest.TestCase):
    def make_game(self, folder):
        (Path(folder) / '0100000000010000_build').mkdir()
        return backend.Game(Path(folder))

    def test_defaults_change_nothing(self):
        with tempfile.TemporaryDirectory() as folder:
            game = self.make_game(folder)
            self.assertEqual(backend.write_env(game, 'handheld', 512).read_text(), backend.write_env(game, 'handheld', 512, pso_mtl4=False, extra_env=[]).read_text())
            self.assertNotIn('DM_PSO_MTL4', backend.write_env(game, 'handheld', 512).read_text())
        self.assertEqual(backend.pipeline_gpu(SimpleNamespace()), 'none')
        self.assertEqual(backend.pipeline_gpu(SimpleNamespace(gpu='  ')), 'none')
        self.assertEqual(backend.extractor_options(SimpleNamespace(allow_damaged_manual=False, nx_extract_arg=[])), [])

    def test_metal4_and_extra_switches_reach_the_env_file(self):
        with tempfile.TemporaryDirectory() as folder:
            game = self.make_game(folder)
            text = backend.write_env(game, 'handheld', 512, pso_mtl4=True, extra_env=['DM_FOO=1\n\n# note\nDM_BAR=a b', 'DM_OPMODE=1']).read_text()
        self.assertIn('DM_PSO_MTL4=1\n', text)
        self.assertIn('DM_FOO=1\n', text)
        self.assertIn('DM_BAR=a b\n', text)
        self.assertEqual(text.count('DM_OPMODE'), 1)   # the player's own value replaces the generated one
        self.assertIn('DM_OPMODE=1', text)
        self.assertNotIn('note', text)

    def test_game_memory_paging_is_a_three_way_choice(self):
        with tempfile.TemporaryDirectory() as folder:
            game = self.make_game(folder)
            self.assertNotIn('DM_GUEST_FILE', backend.write_env(game, 'handheld', 512).read_text())
            self.assertNotIn('DM_GUEST_FILE', backend.write_env(game, 'handheld', 512, guest_file=None).read_text())
            self.assertIn('DM_GUEST_FILE=1\n', backend.write_env(game, 'handheld', 512, guest_file='on').read_text())
            self.assertIn('DM_GUEST_FILE=0\n', backend.write_env(game, 'handheld', 512, guest_file='off').read_text())
        with patch.object(sys, 'argv', ['backend.py', 'build', '/x', '--guest-file', 'on']), patch.object(backend, 'cmd_build') as build, patch.object(backend, 'BUNDLED', False):
            backend.main()
        self.assertEqual(build.call_args.args[0].guest_file, 'on')

    def test_bad_switches_are_refused(self):
        for bad in ('dm_foo=1', 'FOO BAR=1', 'NOEQUALS', '=1', 'A-B=1'):
            with self.assertRaises(backend.Failure, msg=bad):
                backend.extra_env_pairs([bad])
        self.assertEqual(backend.extra_env_pairs(['A=1\n#c\n\nB=']), [('A', '1'), ('B', '')])

    def test_gpu_and_extractor_options_for_the_build_script(self):
        self.assertEqual(backend.pipeline_gpu(SimpleNamespace(gpu='g18p')), 'g18p')
        self.assertEqual(backend.pipeline_gpu(SimpleNamespace(gpu='g18p, g17p')), 'g18p,g17p')
        with self.assertRaises(backend.Failure):
            backend.pipeline_gpu(SimpleNamespace(gpu='rm -rf'))
        args = SimpleNamespace(allow_damaged_manual=True, nx_extract_arg=['--allow-damaged', '--x', 'y'])
        self.assertEqual(backend.extractor_options(args), ['--allow-damaged-manual', '--nx-extract-arg=--allow-damaged', '--nx-extract-arg=--x', '--nx-extract-arg=y'])

    def test_prepare_game_passes_them_on(self):
        def prepare(*extra):
            seen = []
            with tempfile.TemporaryDirectory() as folder:
                game = self.make_game(folder)
                keys = Path(folder) / 'prod.keys'; keys.write_text('x')
                with patch.object(backend, 'stream', side_effect=lambda command, **kw: seen.append([str(c) for c in command])), redirect_stdout(io.StringIO()):
                    try:
                        backend.prepare_game(game, keys, '', 'python3', *extra)
                    except backend.Failure:
                        pass   # nothing was really built
            return seen[0]
        command = prepare(SimpleNamespace(gpu='g18p', allow_damaged_manual=True, nx_extract_arg=['--q']))
        self.assertEqual(command[command.index('--gpu') + 1], 'g18p')
        self.assertIn('--allow-damaged-manual', command)
        self.assertIn('--nx-extract-arg=--q', command)
        command = prepare()
        self.assertEqual(command[command.index('--gpu') + 1], 'none')
        self.assertFalse([c for c in command if 'damaged' in c or 'nx-extract' in c])

    def test_metal4_keeps_the_pulling_libraries_in_the_build(self):
        with tempfile.TemporaryDirectory() as folder:
            game = self.make_game(folder)
            for on in (False, True):
                args = SimpleNamespace(fps=False, mode='handheld', texture_cap=512, players='', render_scale=1, no_thermal_cap=False, fps_target=0, swap_ab_xy=False, swap_ab=None, swap_xy=None,
                                       art=None, art_scale=0, art_x=0, art_y=0, shelf_art=None, shelf_scale=0, shelf_x=0, shelf_y=0, pso_mtl4=on, extra_env=['DM_X=1'])
                with patch.object(backend, 'restore_tables'), patch.object(backend, 'stream') as stream:
                    backend.generate_project(game, args, 'TEAM', 'test.game', sys.executable)
                env = stream.call_args.kwargs['env']
                self.assertEqual(env.get('IOS_PULL') == '1', on)
                text = Path(env['DM_ENV_FILE']).read_text()
                self.assertEqual('DM_PSO_MTL4=1' in text, on)
                self.assertIn('DM_X=1', text)

    def test_parser_takes_the_options(self):
        with patch.object(sys, 'argv', ['backend.py', 'build', '/x', '--allow-damaged-manual', '--nx-extract-arg=--a', '--nx-extract-arg=b', '--pso-mtl4', '--gpu', 'g18p', '--extra-env', 'A=1']):
            with patch.object(backend, 'cmd_build') as build, patch.object(backend, 'BUNDLED', False):
                backend.main()
        args = build.call_args.args[0]
        self.assertTrue(args.allow_damaged_manual and args.pso_mtl4)
        self.assertEqual((args.nx_extract_arg, args.gpu, args.extra_env), (['--a', 'b'], 'g18p', ['A=1']))


if __name__ == '__main__':
    unittest.main()
