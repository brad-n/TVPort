"""inspect_game_addons.main() against the engine's real package-reader API (a stub reader stands in for nx_extract).

Upstream renamed build_ipa_from_nsp.package_title_reader to package_reader (contents(paths) -> {path: records | why}); the
old call raised AttributeError and every Updates & DLC import failed with a misleading prod.keys message. These tests call
main() itself, so an API drift in the engine fails here instead of in the app."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import backend
sys.path.insert(0, str(backend.REPO / 'scripts'))
import build_ipa_from_nsp as nsp
import inspect_game_addons as addons

APP = 0x0100C4C00E73E000


class FakeReader:
    def __init__(self, answers): self.answers = answers
    def contents(self, paths):
        assert isinstance(paths, list), 'package_reader.contents takes a list of paths'
        return {p: self.answers.get(p.name, 'no content meta') for p in paths}


class AddonsMainUsesPackageReader(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        (self.dir / 'Game [0100C4C00E73E000][v0].nsp').write_bytes(b'x')
        (self.dir / 'DLC').mkdir()
        (self.dir / 'DLC' / 'Pack [0100C4C00E73F001][v65536].nsp').write_bytes(b'x')

    def run_main(self, answers):
        @contextlib.contextmanager
        def reader(repo, keys, env):
            yield FakeReader(answers)
        argv = ['inspect_game_addons.py', str(self.dir), '--keys', str(self.dir / 'prod.keys'), '--source', str(self.dir / 'DLC')]
        out = io.StringIO()
        with patch.object(sys, 'argv', argv), patch.object(nsp, 'package_reader', reader), \
                contextlib.redirect_stdout(out):
            code = addons.main()
        return code, json.loads(out.getvalue())

    def test_engine_has_the_reader_main_calls(self):
        self.assertTrue(callable(getattr(nsp, 'package_reader', None)), 'build_ipa_from_nsp.package_reader is gone: update inspect_game_addons.py')

    def test_dlc_is_identified_from_content_metas(self):
        code, result = self.run_main({'Game [0100C4C00E73E000][v0].nsp': [('Application', APP, 0)],
                                      'Pack [0100C4C00E73F001][v65536].nsp': [('AddOnContent', APP + 0x1001, 65536)]})
        self.assertEqual(code, 0)
        self.assertEqual(result['title_id'], '0100C4C00E73E000')
        self.assertEqual([(a['kind'], a['version']) for a in result['addons']], [('DLC', 65536)])

    def test_unreadable_package_reports_the_reason(self):
        code, result = self.run_main({'Game [0100C4C00E73E000][v0].nsp': [('Application', APP, 0)],
                                      'Pack [0100C4C00E73F001][v65536].nsp': 'master key 13 is missing from prod.keys'})
        self.assertEqual(code, 1)
        self.assertIn('master key 13 is missing', result['error'])


if __name__ == '__main__':
    unittest.main()
