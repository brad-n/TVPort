#!/usr/bin/env python3
"""The translator options every game gets without a profile key (dmsh_build.py XLATE_DEFAULT, xlate_opts; the defaults pass of 2026-11-09): the exact forms on
(shader_fragw_fold, shader_ftz_cmp, shader_unord_cmp, shader_raw_regs, shader_no_rescale, and dmsh_wide.py's shader_wide_device), shader_raw_loop off, and a profile's 0 or 1
deciding over the default. Each form's own test checks its output (test_dmsh_fragw.py, test_dmsh_cmp_forms.py, test_dmsh_raw_compact.py, test_dmsh_wide.py)."""
import ast
from pathlib import Path
import unittest

SRC = (Path(__file__).resolve().parents[1] / 'tools' / 'dmsh_build.py').read_text()
NAMES = {'XLATE_KEYS', 'XLATE_DEFAULT', 'xlate_opts'}
scope = {}
body = [n for n in ast.parse(SRC).body
        if (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in NAMES for t in n.targets)) or (isinstance(n, ast.FunctionDef) and n.name in NAMES)]
exec(compile(ast.Module(body=body, type_ignores=[]), 'dmsh_build.py', 'exec'), scope)


def profile(**keys):
    return lambda k, default=None: keys.get(k, default)


class Defaults(unittest.TestCase):
    def test_a_profile_without_keys_gets_every_exact_form(self):
        self.assertEqual(scope['xlate_opts'](profile()), {'fragw_fold': True, 'ftz_cmp': True, 'unord_cmp': True, 'raw_regs': True, 'no_rescale': True})
        self.assertEqual(scope['XLATE_DEFAULT']['shader_wide_device'], '1')

    def test_raw_loop_stays_off(self):
        self.assertNotIn('raw_loop', scope['xlate_opts'](profile()))
        self.assertIn('raw_loop', scope['xlate_opts'](profile(shader_raw_loop='1')))

    def test_a_profile_key_turns_one_off(self):
        opts = scope['xlate_opts'](profile(shader_unord_cmp='0', shader_raw_regs='0'))
        self.assertNotIn('unord_cmp', opts); self.assertNotIn('raw_regs', opts)
        self.assertIn('ftz_cmp', opts)

    def test_every_key_has_a_default(self):
        self.assertEqual(set(scope['XLATE_KEYS']) | {'shader_wide_device'}, set(scope['XLATE_DEFAULT']))


if __name__ == '__main__':
    unittest.main()
