"""NSP script: extra nx_extract arguments (--nx-extract-arg, NX_EXTRACT_ARGS) reach the extraction calls only, and --allow-damaged-manual reaches the HTML manual's call only."""
import os
import unittest
from unittest import mock

from test_nsp_external_drive import nsp


class NxExtractArgs(unittest.TestCase):
    def setUp(self):
        for name, value in (('NX_EXTRACT_ARGS', []), ('ALLOW_DAMAGED_MANUAL', False), ('ALLOW_DAMAGED', False), ('PROGRAM_INDEX', 0)):
            p = mock.patch.object(nsp, name, value); p.start(); self.addCleanup(p.stop)

    def test_defaults_add_nothing(self):
        self.assertEqual(nsp.extract_flags(0x10), ['--app', '0000000000000010'])
        self.assertEqual(nsp.html_flags(0x10), ['--app', '0000000000000010'])

    def test_extra_args_follow_the_extraction_flags(self):
        nsp.NX_EXTRACT_ARGS = ['--foo', 'bar']
        self.assertEqual(nsp.extract_flags(0x10)[-2:], ['--foo', 'bar'])
        self.assertEqual(nsp.html_flags(0x10)[-2:], ['--foo', 'bar'])

    def test_allow_damaged_in_the_args_is_not_doubled(self):
        nsp.NX_EXTRACT_ARGS = ['--allow-damaged']; nsp.ALLOW_DAMAGED = True
        self.assertEqual(nsp.extract_flags(0x10).count('--allow-damaged'), 1)
        self.assertEqual(nsp.html_flags(0x10).count('--allow-damaged'), 1)

    def test_environment_is_split_as_shell_words_after_the_options(self):
        with mock.patch.dict(os.environ, {'NX_EXTRACT_ARGS': '--a "b c" --d'}):
            self.assertEqual(nsp.nx_extract_args(['--first']), ['--first', '--a', 'b c', '--d'])
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop('NX_EXTRACT_ARGS', None)
            self.assertEqual(nsp.nx_extract_args(None), [])

    def test_manual_only_flag_reaches_only_the_html_call(self):
        nsp.ALLOW_DAMAGED_MANUAL = True
        self.assertNotIn('--allow-damaged', nsp.extract_flags(0x10))
        self.assertIn('--allow-damaged', nsp.html_flags(0x10))

    def test_extract_html_passes_it_to_nx_extract(self):
        import tempfile
        from pathlib import Path
        nsp.ALLOW_DAMAGED_MANUAL = True
        with tempfile.TemporaryDirectory() as t, mock.patch.object(nsp, 'run') as run, mock.patch.object(nsp, 'swap_in'):
            nsp.extract_html('nx', 'keys', Path(t), 'base', None, Path(t), 0x10)
        self.assertIn('--allow-damaged', run.call_args[0][0])
        self.assertIn('--html', run.call_args[0][0])

    def test_parser_has_the_options(self):
        a = nsp.parse_args(['x', '--allow-damaged-manual', '--nx-extract-arg=--q', '--nx-extract-arg=--r'])
        self.assertTrue(a.allow_damaged_manual)
        self.assertEqual(a.nx_extract_arg, ['--q', '--r'])


if __name__ == '__main__':
    unittest.main()
