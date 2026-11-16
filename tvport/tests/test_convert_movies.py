"""Convert movies (docs/reference/movies.md, "AV1 movies as HEVC sidecars on the Apple TV"): Automatic (on) by default, dm/tools/movie_hevc.py run in the build, its pack sent
beside romfs.img (and not again while the copy there is the one that arrived whole), an earlier build's pack emptied when the option is off, and the build never failing for it."""
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


def quiet(call):
    out = io.StringIO()
    with redirect_stdout(out):
        result = call()
    return result, out.getvalue()


class Option(unittest.TestCase):
    def test_the_build_command_takes_movies(self):
        for argv, expected in ((['--movies', 'off'], 'off'), (['--movies', 'on'], 'on'), ([], 'auto')):
            with patch.object(sys, 'argv', ['backend.py', 'build', '/x'] + argv), patch.object(backend, 'cmd_build') as build, patch.object(backend, 'BUNDLED', False):
                backend.main()
            self.assertEqual(build.call_args.args[0].movies, expected)

    def test_automatic_is_on(self):
        for choice, expected in (('auto', True), ('on', True), ('off', False), (None, True)):
            self.assertEqual(backend.movies_enabled(SimpleNamespace(movies=choice)), expected, choice)
        self.assertTrue(backend.movies_enabled(SimpleNamespace()))

    def test_the_app_passes_the_choice(self):
        model = (backend.REPO / 'tvport/app/Sources/Model.swift').read_text()
        self.assertIn('if let choice = convertMovies, choice == "on" || choice == "off" { arguments += ["--movies", choice] }', model)
        self.assertIn('Picker("Convert movies", selection: convertMoviesBinding)', (backend.REPO / 'tvport/app/Sources/Views.swift').read_text())


class Convert(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / 'RomFS.img').write_bytes(b'DMROMFS1')
        self.game = SimpleNamespace(build=self.root / 'build', romfs=self.root / 'RomFS.img')

    def tool_writes(self, report):
        def fake(argv, **kw):
            out = Path(argv[argv.index('--out') + 1])
            out.mkdir(parents=True, exist_ok=True)
            (out / backend.MOVIE_PACK).write_bytes(b'DMHEVC01' + bytes(56))
            (out / 'report.json').write_text(json.dumps(report))
        return fake

    def test_off_runs_nothing(self):
        with patch.object(backend, 'stream') as stream:
            self.assertIsNone(backend.convert_movies(self.game, SimpleNamespace(movies='off'), 'python3'))
        stream.assert_not_called()

    def test_the_tool_runs_with_reuse_and_its_pack_is_returned(self):
        report = {'converted': 26, 'av1_bytes': 1.64e9, 'hevc_bytes': 1.2e9}
        with patch.object(backend, 'stream', side_effect=self.tool_writes(report)) as stream:
            pack, text = quiet(lambda: backend.convert_movies(self.game, SimpleNamespace(movies='auto'), 'python3'))
        self.assertEqual(pack, self.root / 'build/tvport-movies' / backend.MOVIE_PACK)
        argv = stream.call_args.args[0]
        self.assertEqual(argv[:4], ['python3', '-I', backend.REPO / 'dm/tools/movie_hevc.py', self.game.romfs])
        self.assertEqual(argv[argv.index('--out') + 1], self.root / 'build/tvport-movies')
        self.assertIn('--reuse', argv)
        self.assertIn('26 AV1 movies as HEVC', text)
        self.assertIn('"name": "Converting movies"', text)

    def test_no_av1_movie_sends_nothing(self):
        with patch.object(backend, 'stream', side_effect=self.tool_writes({'converted': 0})):
            pack, _ = quiet(lambda: backend.convert_movies(self.game, SimpleNamespace(movies='on'), 'python3'))
        self.assertIsNone(pack)

    def test_a_failure_leaves_the_movies_and_the_build_goes_on(self):
        with patch.object(backend, 'stream', side_effect=backend.Failure('movie_hevc: ffmpeg was not found (Homebrew: brew install ffmpeg)')):
            pack, text = quiet(lambda: backend.convert_movies(self.game, SimpleNamespace(movies='on'), 'python3'))
        self.assertIsNone(pack)
        self.assertIn('Movies are left as they are: they could not be converted (movie_hevc: ffmpeg was not found', text)
        self.game.romfs = None
        pack, text = quiet(lambda: backend.convert_movies(self.game, SimpleNamespace(movies='on'), 'python3'))
        self.assertIsNone(pack)
        self.assertIn('there is no RomFS image', text)


class Install(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.pack = Path(tmp.name) / backend.MOVIE_PACK
        self.pack.write_bytes(b'x' * 1000)

    def test_sent_once_then_kept(self):
        with patch.object(backend, 'send_file') as send, patch.object(backend, 'installed_files', return_value={backend.MOVIE_PACK: 1000}):
            _, text = quiet(lambda: backend.install_movies(self.pack, 'dev', 'b', None))
            self.assertEqual(send.call_args.args[1:], (self.pack, backend.MOVIE_PACK, 'dev', 'b'))
            self.assertIn('match this Mac', text)
            send.reset_mock()
            _, text = quiet(lambda: backend.install_movies(self.pack, 'dev', 'b', 1000))
            send.assert_not_called()
            self.assertIn('already on the Apple TV', text)
            _, text = quiet(lambda: backend.install_movies(self.pack, 'other', 'b', 1000))   # another Apple TV
            send.assert_called_once()

    def test_a_copy_cut_short_or_a_failed_send_is_logged_not_fatal(self):
        with patch.object(backend, 'send_file'), patch.object(backend, 'installed_files', return_value={backend.MOVIE_PACK: 10}):
            _, text = quiet(lambda: backend.install_movies(self.pack, 'dev', 'b', None))
        self.assertIn('did not arrive whole (10 bytes of 1000)', text)
        self.assertFalse(self.pack.with_name(self.pack.name + '.sent').exists())
        with patch.object(backend, 'send_file', side_effect=backend.Failure('network')):
            _, text = quiet(lambda: backend.install_movies(self.pack, 'dev', 'b', None))
        self.assertIn('could not be sent (network)', text)

    def test_off_empties_an_earlier_pack_and_a_failed_conversion_leaves_it(self):
        with patch.object(backend, 'send_file') as send:
            quiet(lambda: backend.install_movies(None, 'dev', 'b', 5000, off=True))
            self.assertEqual(send.call_args.args[2:], (backend.MOVIE_PACK, 'dev', 'b'))
            self.assertEqual(send.call_args.args[1].name, 'empty')
            send.reset_mock()
            quiet(lambda: backend.install_movies(None, 'dev', 'b', 5000, off=False))   # on, but not made this time: the pack there still serves the units it holds
            quiet(lambda: backend.install_movies(None, 'dev', 'b', 0, off=True))       # already empty
            quiet(lambda: backend.install_movies(None, 'dev', 'b', None, off=True))    # never sent
            send.assert_not_called()

    def test_install_sends_it_after_the_game_files(self):
        root = self.pack.parent
        (root / 'App.app').mkdir(); (root / 'App.app/embedded.mobileprovision').write_text('x')
        (root / 'romfs.img').write_bytes(b'x' * 100)
        game = SimpleNamespace(app=root / 'App.app', romfs=root / 'romfs.img')
        with patch.object(backend, 'run', return_value=SimpleNamespace(returncode=0, stderr='', stdout='')), \
             patch.object(backend, 'installed_files', return_value={'romfs.img': 100, backend.MOVIE_PACK: 7}), patch.object(backend, 'install_movies') as movies:
            quiet(lambda: backend.install(game, 'dev', 'b', movies=self.pack, movies_off=False))
        self.assertEqual(movies.call_args.args, (self.pack, 'dev', 'b', 7, False))


class Build(unittest.TestCase):
    def test_cmd_build_converts_and_hands_the_pack_to_the_install(self):
        for choice, pack in (('auto', Path('/b/tvport-movies/movies-hevc.pack')), ('off', None)):
            args = SimpleNamespace(folder='/g', team='T', keys=None, device='dev', texture_cap=512, astc='off', texture_once='auto', compress_data='off', icloud=False, art=None,
                                   mode='handheld', render_scale=1, movies=choice)
            game = SimpleNamespace(build=Path('/b'), romfs=Path('/r'), app=Path('/a'), prepared=True, addons=[], input_signature=lambda: 's', state=lambda: {'source_signature': 's'},
                                   bundle_id=lambda team: 'b', save_state=lambda **kw: None)
            with patch.object(backend, 'Game', return_value=game), patch.object(backend, 'known_team', return_value='T'), patch.object(backend, 'relocate_build', return_value=game), \
                 patch.object(backend, 'BUNDLED', False), patch.object(backend, 'engine_python', return_value='python3'), patch.object(backend, 'one_build_at_a_time'), \
                 patch.object(backend, 'engine_change', return_value=None), patch.object(backend, 'astc_blocks', return_value=(0, None)), patch.object(backend, 'astc_format_blocks', return_value=None), \
                 patch.object(backend, 'remember_shaders'), patch.object(backend, 'backup_saves', return_value={'state': 'none', 'files': 0}), patch.object(backend, 'generate_project'), \
                 patch.object(backend, 'bundle_shaders'), patch.object(backend, 'compile_app'), patch.object(backend, 'install') as install, patch.object(backend, 'trim_shaders', return_value=None), patch.object(backend, 'prewarm_pipelines'), \
                 patch.object(backend, 'restore_saves', return_value=0), patch.object(backend, 'provisioning', return_value={}), \
                 patch.object(backend, 'convert_movies', return_value=pack) as convert, redirect_stdout(io.StringIO()):
                backend.cmd_build(args)
            self.assertEqual(convert.call_args.args[1:], (args, 'python3'))
            self.assertEqual(install.call_args.kwargs, {'movies': pack, 'movies_off': choice == 'off'})


if __name__ == '__main__':
    unittest.main()
