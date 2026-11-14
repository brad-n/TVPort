"""DM_TV_OUTPUT (1080 or 2160): every place the host tells a game the display size reads it (hle_oe.c dm_display_size, hle_vi.c, hle_vk.m), the setting is documented, and
the switch is read only on a Mac. The reported sizes per mode are checked by dm/host/tests/t_oe.c."""
import os, re, unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))


def read(*p):
    with open(os.path.join(ROOT, *p), encoding='utf-8') as f: return f.read()


class TvOutput(unittest.TestCase):
    def test_every_display_report_follows_it(self):
        oe, vi, vk = read('dm/host/hle_oe.c'), read('dm/gfx/hle_vi.c'), read('dm/gfx/vk/hle_vk.m')
        self.assertRegex(oe, r'h_oe_DefRes, int \*w, int \*h\) \{\s*dm_display_size\(w, h\);')
        self.assertIn('dm_tv_output() == 2160', vi)
        self.assertRegex(vi, r'lim\[1\] = 3840; lim\[2\] = 2160')           # ListDisplays: the largest layer
        self.assertRegex(vi, r'dm_tv_output\(\) == 2160\) \{ r = 3;')          # QueryDisplayBufferMaxResolution: 4K
        self.assertRegex(vk, r'surf_ext\(void\).*3840, 2160')
        self.assertRegex(vk, r'maxImageExtent = dm_tv_output\(\) == 2160 \? \(VkExtent2D\)\{3840, 2160\}')

    def test_only_a_mac_reads_it(self):
        oe = read('dm/host/hle_oe.c')
        self.assertRegex(oe, r'#if TARGET_OS_OSX\s+const int mac = 1;\s+#else\s+const int mac = 0;')
        self.assertIn('return mac && e && atoi(e) == 2160 ? 2160 : 1080;', oe)

    def test_documented(self):
        rows = [l.split('\t') for l in read('docs/env_switches.tsv').splitlines()]
        row = [r for r in rows if r[0] == 'DM_TV_OUTPUT']
        self.assertEqual(len(row), 1); self.assertEqual(row[0][1], 'player')
        self.assertIn('### TV output', read('docs/settings.md'))
        self.assertIn('(`DM_TV_OUTPUT`)', read('docs/reference/rendering.md'))
        self.assertRegex(read('README.md'), r'DM_TV_OUTPUT')


if __name__ == '__main__': unittest.main()
