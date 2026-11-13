"""The patch area a frame step or STUBS stub's code goes into: the one that reaches its site (patch_nso.py stub_site and use_area, extracted as the other rewriter tests
extract their parts), without game files. A main of more text than a branch reaches has two areas (TWO): Star Fox's frame step sites, about 180 MB into its 192 MB of text,
were given code in the front area before the base, and the branch back failed B()'s reach check."""
import ast
from pathlib import Path
import sys
import unittest

REPO = Path(__file__).resolve().parents[3]
SOURCE = REPO / 'dm/tools/patch_nso.py'
sys.path.insert(0, str(REPO / 'dm/tools'))
import nso_asm   # noqa: E402


def area_parts(**globs):
    """use_area, here, emit and stub_site from patch_nso.py, run with the given module globals"""
    tree = ast.parse(SOURCE.read_text())
    body: list[ast.stmt] = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in ('use_area', 'here', 'emit', 'stub_site')]
    ns = {'struct': __import__('struct'), 'fix': [], 'kinds': {}, 'windows': [], **globs}
    exec(compile(ast.Module(body=body, type_ignores=[]), str(SOURCE), 'exec'), ns)
    return ns


class StubArea(unittest.TestCase):
    TEXT = 0xbff3380                     # Star Fox v131072 main: text end
    FRONT, BACK = -0x1000000, 0xf220000   # the front area 16 MB before the base, the back area after the image, bss, the key page and the frame step page
    SPLIT = 0x6f00000

    def parts(self, two):
        img = bytearray(self.TEXT)
        img[0xb4498e4:0xb4498e8] = bytes.fromhex('0b78291e')
        front, back = bytearray(), bytearray()
        return area_parts(TWO=two, SPLIT=self.SPLIT if two else None, IMG=img, patch=front, patch_front=front, patch_back=back,
                          PATCH_BASE=self.FRONT, PATCH_OFF=self.FRONT, BACK_OFF=self.BACK)

    def test_a_far_site_gets_its_code_in_the_back_area(self):
        ns = self.parts(True)
        ns['stub_site'](0xb4498e4, '0b78291e', 'frame step')
        at = ns['here']()
        self.assertEqual(at, self.BACK)
        ns['emit'](0x1e29780b)
        nso_asm.B(ns['here'](), 0xb4498e4 + 4)   # the branch back is in reach (asserted)
        self.assertEqual(len(ns['patch_back']), 4)
        self.assertEqual(len(ns['patch_front']), 0)

    def test_a_near_site_and_one_area_keep_the_front_area(self):
        ns = self.parts(True)
        ns['IMG'][0x100000:0x100004] = bytes.fromhex('0b78291e')
        ns['stub_site'](0x100000, '0b78291e', 'frame step')
        self.assertEqual(ns['here'](), self.FRONT)
        ns = self.parts(False)
        ns['stub_site'](0xb4498e4, '0b78291e', 'frame step')
        self.assertEqual(ns['here'](), self.FRONT)

    def test_the_front_area_could_not_reach_the_far_site(self):
        with self.assertRaises(AssertionError):
            nso_asm.B(self.FRONT, 0xb4498e4 + 4)

    def test_a_wrong_original_still_stops_the_rewrite(self):
        ns = self.parts(True)
        with self.assertRaises(AssertionError):
            ns['stub_site'](0xb4498e4, '00000000', 'frame step')


if __name__ == '__main__':
    unittest.main()
