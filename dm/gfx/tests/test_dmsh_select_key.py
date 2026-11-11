"""The profile key shader_select_guards (dm/games/README.md): 1, the default, writes bounded uniform reads at computed offsets as a load and a select (dmsh_fetch.select_guards,
upstream 918e9f34); 0 leaves spirv-cross's branches. Every place the build ran select_guards goes through the key, and Ocarina of Time sets 0: its fluid volume compute
9ed48d1011f1b48b drew no ground mist on Apple8 GPUs with the selects (dm/games/0400486024DEC000/README.md)"""
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / 'gfx' / 'tools'
sys.path.insert(0, str(TOOLS))
import dmsh_fetch  # noqa: E402

BUILD_SRC = (TOOLS / 'dmsh_build.py').read_text()
# a computed-offset read as spirv-cross writes it, with its condition a value of its own
READ = '''    bool _7 = ((uint(_5) << 2u) | uint(_6)) < ((*spvDescriptorSet0.cp_c25)._m0[0].x >> 2u);
    float _8 = _7 ? (*spvDescriptorSet0.cp_c3)._m0[_7 ? _5 : 0][_6] : 0.0;
'''


class SelectKey(unittest.TestCase):
    def test_default_one_and_every_call_through_it(self):
        self.assertRegex(BUILD_SRC, r"(?m)^SELECT_GUARDS = GAME\.get\('shader_select_guards', '1'\) == '1'")
        self.assertRegex(BUILD_SRC, r"(?m)^def guards\(msl\): return dmsh_fetch\.select_guards\(msl\) if SELECT_GUARDS else msl")
        self.assertEqual(BUILD_SRC.count('dmsh_fetch.select_guards('), 1)   # only inside guards
        self.assertEqual(len(re.findall(r'\bguards\(', BUILD_SRC)) - 1, 3)   # the shader, the geometry stage and its reader

    def test_the_key_chooses_the_form(self):
        msl = 'struct spvDescriptorSetBuffer0 {};\n' + READ
        self.assertIn('select(0.0, (*spvDescriptorSet0.cp_c3)._m0[_7 ? _5 : 0][_6], _7)', dmsh_fetch.select_guards(msl))   # 1: upstream's select

    def test_ocarina_keeps_branches(self):
        self.assertRegex((ROOT / 'games' / '0400486024DEC000' / 'game.tsv').read_text(), r'(?m)^shader_select_guards\t0$')
        self.assertIn("ssg not in ('0', '1')", (ROOT / 'games' / 'game.py').read_text())


if __name__ == '__main__':
    unittest.main()
