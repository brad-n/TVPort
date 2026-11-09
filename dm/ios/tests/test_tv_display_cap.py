"""The Apple TV draws at most DM_TV_MAX_WIDTH pixels across (1920 by default) and tells a docked Switch 2 game that display size (DmDisplayCap.h, front_ios.m).

A 4K TV otherwise gets a 3840x2160 drawable for a picture the game renders at 1920x1080 at most in handheld mode: one more full-screen upscale each frame and three
4K drawables (about 100 MB against 25 MB at 1080p), on a device that ends the game near 2 GB. Docked, a Switch 2 game asks for the display's largest buffer
(vi QueryDisplayBufferMaxResolution, hle_vi.c) and renders its output at 4K for a 4K screen. The TV's display hardware scales the 1080p layer to the screen."""
import re, subprocess, tempfile, unittest
from pathlib import Path

IOS = Path(__file__).resolve().parents[1]
PROGRAM = r'''
#include <stdio.h>
#include "DmDisplayCap.h"
int main(void) {
    const char *in[] = { 0, "", "0", "1920", "3840", "1280", "abc", "-5", "12x", "100" };
    for (unsigned i = 0; i < sizeof in / sizeof *in; i++) printf("%d\n", dm_tv_max_width(in[i]));
    int s[][3] = { {3840, 2160, 1920}, {1920, 1080, 1920}, {3840, 2160, 0}, {2560, 1080, 1920}, {1280, 720, 1920}, {3840, 2160, 2560} };
    for (unsigned i = 0; i < sizeof s / sizeof *s; i++) { int w = s[i][0], h = s[i][1]; dm_cap_display(&w, &h, s[i][2]); printf("%dx%d\n", w, h); }
    return 0;
}
'''


class TvDisplayCapTests(unittest.TestCase):
    def test_width_switch_and_display_cap(self):
        with tempfile.TemporaryDirectory() as t:
            src, exe = Path(t) / 'cap.c', Path(t) / 'cap'
            src.write_text(PROGRAM)
            subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(IOS / 'Sources'), str(src), '-o', str(exe)], check=True)
            out = subprocess.run([str(exe)], capture_output=True, text=True, check=True).stdout.split()
        # unset / empty / not a whole number: 1920; 0: the screen's own pixels; below 640 is raised to 640
        self.assertEqual(out[:10], ['1920', '1920', '0', '1920', '3840', '1280', '1920', '1920', '1920', '640'])
        self.assertEqual(out[10:], ['1920x1080', '1920x1080', '3840x2160', '1920x810', '1280x720', '2560x1440'])

    def test_front_end_applies_the_cap_on_tvos_only(self):
        src = (IOS / 'Sources/front_ios.m').read_text()
        self.assertIn('#include "DmDisplayCap.h"', src)
        init = src[src.index('- (instancetype)initWithFrame:(CGRect)f {'):src.index('- (void)didMoveToWindow')]
        self.assertRegex(init, r'#if TARGET_OS_TV\s+self\.maxPixelWidth = dm_tv_max_width\(getenv\("DM_TV_MAX_WIDTH"\)\);')
        disp = src[src.index('int front_display_pixels(int *w, int *h) {'):]
        disp = disp[:disp.index('\n}\n')]
        self.assertRegex(disp, r'#if TARGET_OS_TV\s+dm_cap_display\(w, h, dm_tv_max_width\(getenv\("DM_TV_MAX_WIDTH"\)\)\);')

    def test_switch_is_documented(self):
        rows = (IOS.parents[1] / 'docs/env_switches.tsv').read_text()
        self.assertTrue(re.search(r'^DM_TV_MAX_WIDTH\t', rows, re.M))


if __name__ == '__main__':
    unittest.main()
