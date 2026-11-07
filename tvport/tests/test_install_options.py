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


class CompressedTextures(unittest.TestCase):
    """The per-game Compressed textures (ASTC) choice: Automatic / On / Off and the block size, the prebuild step, and the pack's trip to the Apple TV"""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        (root / 'App.app').mkdir(); (root / 'App.app/embedded.mobileprovision').write_text('x')
        (root / 'romfs.img').write_bytes(b'x' * 100)
        self.pack = root / 'astc-ro.pack'
        self.pack.write_bytes(b'NXASTCPK' + bytes(32) + bytes(range(32)) + bytes(8) + b'p' * 20)   # 80 bytes of header with a fingerprint, 20 of body
        self.game = SimpleNamespace(app=root / 'App.app', romfs=root / 'romfs.img')
        patcher = patch('time.sleep'); self.sleep = patcher.start(); self.addCleanup(patcher.stop)

    def install(self, listings, copy=None):
        out = io.StringIO()
        with patch.object(backend, 'run', return_value=done(0)), patch.object(backend, 'stream', side_effect=copy) as stream, patch.object(backend, 'installed_files', side_effect=listings), redirect_stdout(out):
            backend.install(self.game, 'd', 'b', self.pack)
        return stream, out.getvalue()

    def test_automatic_is_on_with_4x4_and_off_writes_a_zero(self):
        self.assertEqual(backend.astc_block(SimpleNamespace()), 4)
        self.assertEqual(backend.astc_block(SimpleNamespace(astc='auto', astc_block=4)), 4)
        self.assertEqual(backend.astc_block(SimpleNamespace(astc='on', astc_block=6)), 6)
        self.assertEqual(backend.astc_block(SimpleNamespace(astc='auto', astc_block=6)), 6)
        self.assertEqual(backend.astc_block(SimpleNamespace(astc='off', astc_block=6)), 0)
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / '0100000000010000_build').mkdir()
            game = backend.Game(Path(folder))
            self.assertNotIn('DM_NVN_BC_ASTC', backend.write_env(game, 'handheld', 512).read_text())   # nothing asked: nothing written
            self.assertIn('DM_NVN_BC_ASTC=4\n', backend.write_env(game, 'handheld', 512, astc_block=4).read_text())
            self.assertIn('DM_NVN_BC_ASTC=6\n', backend.write_env(game, 'handheld', 512, astc_block=6).read_text())
            self.assertIn('DM_NVN_BC_ASTC=0\n', backend.write_env(game, 'handheld', 512, astc_block=0).read_text())
            text = backend.write_env(game, 'handheld', 512, astc_block=4, extra_env=['DM_NVN_BC_ASTC=6']).read_text()
            self.assertEqual(text.count('DM_NVN_BC_ASTC'), 1)   # the player's own switch replaces the generated one
            self.assertIn('DM_NVN_BC_ASTC=6\n', text)

    def test_the_block_size_picker_maps_to_blocks_flags_and_env(self):
        # Matched to the original (the default: nothing saved), 4x4, 6x6 -> (block, bc1_block)
        for choice, want in ((None, (4, 6)), ('matched', (4, 6)), ('4', (4, 4)), (4, (4, 4)), ('6', (6, 6)), (6, (6, 6)), ('weird', (4, 6))):
            self.assertEqual(backend.astc_blocks(SimpleNamespace(astc='auto', astc_block=choice)), want, choice)
        self.assertEqual(backend.astc_blocks(SimpleNamespace()), (4, 6))
        self.assertEqual(backend.astc_blocks(SimpleNamespace(astc='off', astc_block='matched')), (0, 0))
        self.assertEqual(backend.astc_block(SimpleNamespace(astc='on', astc_block='matched')), 4)
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / '0100000000010000_build').mkdir()
            game = backend.Game(Path(folder))
            text = backend.write_env(game, 'handheld', 512, astc_block=4, bc1_block=6).read_text()
            self.assertIn('DM_NVN_BC_ASTC=4\n', text)
            self.assertIn('DM_NVN_BC1_ASTC=6\n', text)
            self.assertIn('DM_NVN_BC1_ASTC=4\n', backend.write_env(game, 'handheld', 512, astc_block=4, bc1_block=4).read_text())
            self.assertNotIn('DM_NVN_BC1_ASTC', backend.write_env(game, 'handheld', 512, astc_block=4).read_text())
            self.assertNotIn('DM_NVN_BC1_ASTC', backend.write_env(game, 'handheld', 512, astc_block=0, bc1_block=0).read_text())
        game = SimpleNamespace(build=Path(self.tmp.name), romfs=Path(self.tmp.name) / 'romfs.img')
        (Path(self.tmp.name) / 'tvport-astc').mkdir(exist_ok=True); (Path(self.tmp.name) / 'tvport-astc' / 'astc-ro.pack').write_bytes(b'x')
        with patch.object(backend, 'stream') as stream, redirect_stdout(io.StringIO()):
            backend.prebuild_astc(game, 4, 'python3', 512, 6)
        argv = [str(a) for a in stream.call_args.args[0]]
        self.assertEqual((argv[argv.index('--block') + 1], argv[argv.index('--bc1-block') + 1]), ('4', '6'))

    def test_the_build_command_takes_both_choices(self):
        for argv, expected in ((['--astc', 'off'], ('off', 'matched')), (['--astc', 'on', '--astc-block', '6'], ('on', '6')), (['--astc-block', '4'], ('auto', '4')), (['--astc-block', 'matched'], ('auto', 'matched')), ([], ('auto', 'matched'))):
            with patch.object(sys, 'argv', ['backend.py', 'build', '/x'] + argv), patch.object(backend, 'cmd_build') as build, patch.object(backend, 'BUNDLED', False):
                backend.main()
            self.assertEqual((build.call_args.args[0].astc, build.call_args.args[0].astc_block), expected)

    def test_the_prebuild_runs_the_engine_tool_and_returns_the_pack(self):
        game = SimpleNamespace(build=Path(self.tmp.name), romfs=Path(self.tmp.name) / 'romfs.img')
        made = Path(self.tmp.name) / 'tvport-astc'
        made.mkdir()
        (made / 'astc-ro.pack').write_bytes(b'x')
        with patch.object(backend, 'stream') as stream, redirect_stdout(io.StringIO()):
            self.assertEqual(backend.prebuild_astc(game, 6, 'python3', 512), made / 'astc-ro.pack')
        argv = [str(a) for a in stream.call_args.args[0]]
        self.assertEqual(argv[:2], ['python3', '-I'])
        self.assertTrue(argv[2].endswith('dm/gfx/tools/bntx_astc.py'))
        self.assertEqual(argv[argv.index('--block') + 1], '6')
        self.assertEqual(argv[argv.index('--bc1-block') + 1], '6')   # no BC1 block given: the same
        self.assertEqual(argv[argv.index('--max-dim') + 1], '512')   # the game's texture cap, the same number write_env gives the app as DM_BC_MAX_DIM
        self.assertIn('--drop-cache', argv)

    def test_a_failed_prebuild_does_not_fail_the_build(self):
        game = SimpleNamespace(build=Path(self.tmp.name) / 'nothing', romfs=Path(self.tmp.name) / 'romfs.img')
        out = io.StringIO()
        with patch.object(backend, 'stream', side_effect=backend.Failure('clang: not found')), redirect_stdout(out):
            self.assertIsNone(backend.prebuild_astc(game, 4, 'python3', 0))
        self.assertIn('could not be prepared', out.getvalue())

    def test_the_pack_is_sent_beside_the_game_files_and_its_size_verified(self):
        listings = [{'romfs.img': 100}, {'astc-ro.pack': 100}]
        stream, text = self.install(listings)
        self.assertEqual(stream.call_count, 1)
        argv = [str(a) for a in stream.call_args.args[0]]
        self.assertEqual(argv[argv.index('--destination') + 1], 'Library/Caches/astc-ro.pack')
        self.assertEqual(argv[argv.index('--source') + 1], str(self.pack))
        self.assertIn('compressed textures on the Apple TV match', text)
        self.assertTrue(self.pack.with_name('astc-ro.pack.sent').is_file())

    def test_the_game_files_and_the_pack_both_go_when_neither_is_there(self):
        stream, _ = self.install([{}, {'romfs.img': 100}, {'romfs.img': 100, 'astc-ro.pack': 100}])
        self.assertEqual([str(c.args[0][c.args[0].index('--destination') + 1]) for c in stream.call_args_list], ['Library/Caches/romfs.img', 'Library/Caches/astc-ro.pack'])

    def test_a_pack_already_there_is_not_sent_again(self):
        self.install([{'romfs.img': 100}, {'astc-ro.pack': 100}])
        stream, text = self.install([{'romfs.img': 100, 'astc-ro.pack': 100}])
        stream.assert_not_called()
        self.assertIn('already on the Apple TV', text)

    def test_a_pack_of_the_same_size_but_another_fingerprint_is_sent_again(self):
        self.install([{'romfs.img': 100}, {'astc-ro.pack': 100}])
        body = bytearray(self.pack.read_bytes()); body[40] ^= 1; self.pack.write_bytes(bytes(body))
        stream, _ = self.install([{'romfs.img': 100, 'astc-ro.pack': 100}, {'astc-ro.pack': 100}])
        self.assertEqual(stream.call_count, 1)

    def test_the_pack_copy_is_retried_and_a_short_arrival_fails(self):
        copies = [backend.Failure('Failed to locate coordinated install: connection lost'), None]

        def copy(argv, **kwargs):
            outcome = copies.pop(0)
            if outcome:
                raise outcome
        stream, text = self.install([{'romfs.img': 100}, {'astc-ro.pack': 100}], copy)
        self.assertEqual(stream.call_count, 2)
        self.assertIn('Sending the compressed textures failed (attempt 1 of 3)', text)
        with self.assertRaises(backend.Failure) as error:
            self.install([{'romfs.img': 100}, {'astc-ro.pack': 60}])
        self.assertIn('60 bytes', str(error.exception))
        self.assertFalse(self.pack.with_name('astc-ro.pack.sent').exists())

    def test_without_a_pack_the_install_is_unchanged(self):
        with patch.object(backend, 'run', return_value=done(0)), patch.object(backend, 'stream') as stream, patch.object(backend, 'installed_files', return_value={'romfs.img': 100}) as files, redirect_stdout(io.StringIO()):
            backend.install(self.game, 'd', 'b')
        stream.assert_not_called()
        self.assertEqual(files.call_count, 1)

    def test_the_fingerprint_is_read_from_the_pack_header(self):
        self.assertEqual(backend.pack_fingerprint(self.pack), bytes(range(32)).hex())
        other = Path(self.tmp.name) / 'other'
        other.write_bytes(b'not a pack')
        self.assertEqual(backend.pack_fingerprint(other), '')


class StoreTexturesOnce(unittest.TestCase):
    """docs/texture_once.md section 5: the per-game choice, the tool run in the build, the fallback, and the sparse image's trip to the Apple TV"""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'extract').mkdir(); (self.root / 'build').mkdir()
        (self.root / 'extract/RomFS.img').write_bytes(b'r' * 500)
        (self.root / 'extract/control.nacp').write_bytes(b'n')
        (self.root / 'App.app').mkdir(); (self.root / 'App.app/embedded.mobileprovision').write_text('x')
        self.pack = self.root / 'astc-ro.pack'; self.pack.write_bytes(b'p' * 90)
        self.game = SimpleNamespace(build=self.root / 'build', romfs=self.root / 'extract/RomFS.img', app=self.root / 'App.app')
        self.once = self.root / 'build/tvport-once/romfs.img'
        patcher = patch('time.sleep'); patcher.start(); self.addCleanup(patcher.stop)

    def make_image(self, size=100):
        self.once.parent.mkdir(exist_ok=True)
        self.once.write_bytes(b's' * size)

    def run_tool(self, tool_exists=True, fail=None, make=True):
        """store_textures_once with a fake tex_once.py: returns (result, argv of the tool run or None, log text)"""
        fake_repo = self.root / 'repo'
        tool = fake_repo / 'dm/gfx/tools/tex_once.py'
        if tool_exists:
            tool.parent.mkdir(parents=True, exist_ok=True); tool.write_text('')

        def fake(argv, **kwargs):
            if fail:
                raise backend.Failure(fail)
            if make:
                self.make_image()
        out = io.StringIO()
        with patch.object(backend, 'REPO', fake_repo), patch.object(backend, 'stream', side_effect=fake) as stream, redirect_stdout(out):
            result = backend.store_textures_once(self.game, self.pack, 6, 'python3', 512)
        return result, ([str(a) for a in stream.call_args.args[0]] if stream.called else None), out.getvalue()

    def test_automatic_follows_compressed_textures(self):
        enabled = backend.texture_once_enabled
        for choice, block, expected in (('auto', 4, True), (None, 4, True), ('on', 6, True), ('off', 4, False), ('off', 6, False),
                                         ('auto', 0, False), ('on', 0, False), (None, 0, False)):   # block 0 = Compressed textures Off
            self.assertEqual(enabled(SimpleNamespace(texture_once=choice), block), expected, (choice, block))
        self.assertTrue(enabled(SimpleNamespace(), 4))   # an older caller that does not know the option

    def test_the_build_command_takes_the_choice(self):
        for argv, expected in ((['--texture-once', 'off'], 'off'), (['--texture-once', 'on'], 'on'), ([], 'auto')):
            with patch.object(sys, 'argv', ['backend.py', 'build', '/x'] + argv), patch.object(backend, 'cmd_build') as build, patch.object(backend, 'BUNDLED', False):
                backend.main()
            self.assertEqual(build.call_args.args[0].texture_once, expected)

    def test_the_tool_runs_with_the_pack_cap_and_block_and_its_image_is_returned(self):
        result, argv, _ = self.run_tool()
        self.assertEqual(result, self.once)
        self.assertEqual(argv[:2], ['python3', '-I'])
        self.assertTrue(argv[2].endswith('dm/gfx/tools/tex_once.py'))
        self.assertEqual(argv[3], str(self.game.romfs))
        self.assertEqual(argv[argv.index('--bc1-block') + 1], '6')   # tex_once.py takes the same BC1 block as the prebuild
        self.assertEqual(argv[argv.index('--pack') + 1], str(self.pack))
        self.assertEqual(argv[argv.index('--out') + 1], str(self.root / 'build/tvport-once'))
        self.assertEqual(argv[argv.index('--max-dim') + 1], '512')
        self.assertEqual(argv[argv.index('--block') + 1], '6')
        self.assertTrue((self.once.parent / 'control.nacp').is_symlink())   # build_ipa.sh looks beside the image for it
        self.assertFalse((self.once.parent / 'icon.jpg').exists())

    def test_a_missing_tool_falls_back_with_one_warning(self):
        result, argv, text = self.run_tool(tool_exists=False)
        self.assertIsNone(result)
        self.assertIsNone(argv)
        self.assertEqual(text.count('stored twice'), 1)
        self.assertEqual(len([line for line in text.splitlines() if '"log"' in line]), 1)

    def test_a_failed_tool_falls_back_with_one_warning(self):
        result, _, text = self.run_tool(fail='self-check failed: plane 3')
        self.assertIsNone(result)
        self.assertEqual(len([line for line in text.splitlines() if '"log"' in line]), 1)
        self.assertIn('self-check failed', text)

    def test_a_tool_that_leaves_no_image_falls_back(self):
        self.assertIsNone(self.run_tool(make=False)[0])

    def test_no_pack_means_no_run(self):
        out = io.StringIO()
        with patch.object(backend, 'stream') as stream, redirect_stdout(out):
            self.assertIsNone(backend.store_textures_once(self.game, None, 4, 'python3', 0))
        stream.assert_not_called()

    def test_the_project_is_built_against_the_stripped_image(self):
        args = SimpleNamespace(fps=False, mode='handheld', texture_cap=512, players='', render_scale=1, no_thermal_cap=False, fps_target=0, swap_ab_xy=False, swap_ab=None, swap_xy=None,
                               art=None, art_scale=0, art_x=0, art_y=0, shelf_art=None, shelf_scale=0, shelf_x=0, shelf_y=0, pso_mtl4=False, extra_env=[])
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / '0100000000010000_build').mkdir()
            game = backend.Game(Path(folder))
            seen = []
            for romfs in (None, self.once):
                with patch.object(backend, 'restore_tables'), patch.object(backend, 'stream') as stream, patch.object(backend.Game, 'romfs', Path('/plain/RomFS.img')):
                    backend.generate_project(game, args, 'TEAM', 'test.game', sys.executable, romfs)
                seen.append(stream.call_args.kwargs['env']['ROMFS'])
        self.assertEqual(seen, ['/plain/RomFS.img', str(self.once)])

    def build(self, **options):
        """cmd_build up to the install with everything heavy replaced: returns (generate_project call, install call, store call)"""
        args = SimpleNamespace(folder=str(self.root), team='T', keys=None, device='dev', texture_cap=512, astc=options.get('astc', 'auto'), astc_block=options.get('block', 4), texture_once=options.get('once', 'auto'), icloud=False, art=None, mode='handheld', render_scale=1)
        game = SimpleNamespace(build=self.root / 'build', romfs=self.game.romfs, app=self.game.app, prepared=True, addons=[], input_signature=lambda: 's', state=lambda: {'source_signature': 's'},
                               bundle_id=lambda team: 'b', save_state=lambda **kw: None)
        out = io.StringIO()
        with patch.object(backend, 'Game', return_value=game), patch.object(backend, 'known_team', return_value='T'), patch.object(backend, 'relocate_build', return_value=game), \
             patch.object(backend, 'BUNDLED', False), patch.object(backend, 'engine_python', return_value='python3'), patch.object(backend, 'one_build_at_a_time'), \
             patch.object(backend, 'prebuild_astc', return_value=options.get('pack', self.pack)), patch.object(backend, 'remember_shaders'), \
             patch.object(backend, 'backup_saves', return_value={'state': 'none', 'files': 0}), patch.object(backend, 'generate_project') as generate, patch.object(backend, 'bundle_shaders'), \
             patch.object(backend, 'compile_app'), patch.object(backend, 'install') as install, patch.object(backend, 'restore_saves', return_value=0), patch.object(backend, 'provisioning', return_value={}), \
             patch.object(backend, 'store_textures_once', return_value=options.get('image')) as store, redirect_stdout(out):
            backend.cmd_build(args)
        return generate, install, store

    def test_the_build_passes_the_same_blocks_to_the_prebuild_and_to_texture_once(self):
        generate, install, store = self.build(image=self.once, block='matched')
        self.assertEqual(store.call_args.args[1:], (self.pack, 4, 'python3', 512, 6))

    def test_the_build_uses_the_stripped_image_for_the_app_and_the_install(self):
        generate, install, store = self.build(image=self.once)
        self.assertEqual(store.call_args.args[1:], (self.pack, 4, 'python3', 512, 4))
        self.assertEqual(generate.call_args.args[5], self.once)
        self.assertEqual(install.call_args.args[3:], (self.pack, self.once))

    def test_the_build_skips_the_tool_when_off_or_without_compressed_textures(self):
        for options in ({'once': 'off'}, {'astc': 'off'}, {'pack': None}):
            generate, install, store = self.build(image=self.once, **options)
            store.assert_not_called()
            self.assertIsNone(generate.call_args.args[5], options)
            self.assertIsNone(install.call_args.args[4], options)

    def test_a_failed_tool_builds_and_installs_as_before(self):
        generate, install, _ = self.build(image=None)
        self.assertIsNone(generate.call_args.args[5])
        self.assertEqual(install.call_args.args[3:], (self.pack, None))

    def install_once(self, listings, copy=None):
        out = io.StringIO()
        with patch.object(backend, 'run', return_value=done(0)), patch.object(backend, 'stream', side_effect=copy) as stream, patch.object(backend, 'installed_files', side_effect=listings), redirect_stdout(out):
            backend.install(self.game, 'd', 'b', self.pack, self.once)
        return [[str(a) for a in c.args[0]] for c in stream.call_args_list], out.getvalue()

    def test_the_sparse_image_is_sent_as_romfs_img_with_no_pack_and_the_stale_pack_is_emptied(self):
        self.make_image(100)
        sent, text = self.install_once([{'astc-ro.pack': 90}, {'romfs.img': 100, 'astc-ro.pack': 90}, {'romfs.img': 100, 'astc-ro.pack': 0}])
        self.assertEqual(len(sent), 2)
        first, second = sent
        self.assertEqual(first[first.index('--source') + 1], str(self.once))   # its own size is what is verified: 100, not the 500 of RomFS.img
        self.assertEqual(first[first.index('--destination') + 1], 'Library/Caches/romfs.img')
        self.assertEqual(second[second.index('--destination') + 1], 'Library/Caches/astc-ro.pack')
        self.assertEqual((self.root / 'build/tvport-once/astc-ro.pack.empty').stat().st_size, 0)   # the pack itself is never the source
        self.assertEqual(second[second.index('--source') + 1], str(self.root / 'build/tvport-once/astc-ro.pack.empty'))
        self.assertNotIn(str(self.pack), first + second)
        self.assertIn('gone from the Apple TV', text)

    def test_nothing_is_emptied_when_there_is_no_old_pack(self):
        self.make_image(100)
        sent, _ = self.install_once([{}, {'romfs.img': 100}])
        self.assertEqual(len(sent), 1)

    def test_the_stripped_image_already_there_is_not_sent_again_but_another_of_the_same_size_is(self):
        self.make_image(100)
        self.install_once([{}, {'romfs.img': 100}])
        sent, text = self.install_once([{'romfs.img': 100, 'astc-ro.pack': 0}])
        self.assertEqual(sent, [])
        self.assertIn('already on the Apple TV', text)
        self.once.write_bytes(b't' * 100)   # same size, new content (another cap)
        sent, _ = self.install_once([{'romfs.img': 100}, {'romfs.img': 100}])
        self.assertEqual(len(sent), 1)

    def test_a_short_arrival_of_the_stripped_image_fails(self):
        self.make_image(100)
        with self.assertRaises(backend.Failure) as error:
            self.install_once([{}, {'romfs.img': 40}])
        self.assertIn('40 bytes', str(error.exception))
        self.assertFalse(self.once.with_name('romfs.img.sent').exists())

    def test_a_pack_that_cannot_be_emptied_does_not_fail_the_install(self):
        self.make_image(100)

        def copy(argv, **kwargs):
            if 'astc-ro.pack' in str(argv[-1]):
                raise backend.Failure('devicectl: no')
        sent, text = self.install_once([{'astc-ro.pack': 90}, {'romfs.img': 100}], copy)
        self.assertIn('could not be emptied', text)

    def test_the_game_without_the_option_installs_as_before(self):
        out = io.StringIO()
        with patch.object(backend, 'run', return_value=done(0)), patch.object(backend, 'stream') as stream, patch.object(backend, 'installed_files', side_effect=[{'romfs.img': 500}, {'astc-ro.pack': 90}]), redirect_stdout(out):
            backend.install(self.game, 'd', 'b', self.pack)
        argv = [str(a) for a in stream.call_args.args[0]]
        self.assertEqual(argv[argv.index('--destination') + 1], 'Library/Caches/astc-ro.pack')
        self.assertFalse(self.root.joinpath('build/tvport-once').exists())


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
