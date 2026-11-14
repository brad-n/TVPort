"""Execute Star Fox's two stubs (dm/games/0400E88025B1A000/patches.py) on an emulated ARM64 core, without game files: the render scale at the frame function's cap of the
resolution scale (fminnm s11,s0,s9) and the hold of the dynamic resolution at the scale its update hands on (ldr s0,[x23,#0x238]). Needs the optional unicorn package."""
import importlib
import importlib.util
from pathlib import Path
import struct
import sys
import unittest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools'))

spec = importlib.util.spec_from_file_location('starfox_patches', REPO / 'dm/games/0400E88025B1A000/patches.py')
assert spec is not None and spec.loader is not None
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
try:
    unicorn = importlib.import_module('unicorn')
    arm = importlib.import_module('unicorn.arm64_const')
except ImportError:
    unicorn = arm = None

BASE, AREA, STATE = 0x4000000, 0x800000, 0x900000
FRAME, UPDATE, OBJ = 0x100000, 0x200000, 0x300000   # the matched functions' starts in this test's image (v131072: main+0xb447300, main+0xb45ae40); OBJ stands for x23
CAP_SITE, HOLD_SITE = FRAME + 0x25e4, UPDATE + 0xafc


class Ctx:
    state = STATE
    base = FRAME
    render_scale = 0

    def __init__(self, machine, others=True):
        self.machine, self.cursor, self.sites, self.capabilities = machine, AREA, {}, set()
        self.others = {'dynamic resolution update': UPDATE if others else None}

    def here(self):
        return self.cursor

    def emit(self, word):
        self.machine.mem_write(BASE + self.cursor, struct.pack('<I', word))
        self.cursor += 4

    def site(self, offset, original):
        self.sites[offset] = original

    def put(self, offset, words, reason):
        self.machine.mem_write(BASE + offset, b''.join(struct.pack('<I', w) for w in words))


def bits(value): return struct.unpack('<I', struct.pack('<f', value))[0]
def single(reg): return struct.unpack('<f', struct.pack('<I', reg & 0xffffffff))[0]


def machine_with_stubs(others=True):
    assert unicorn is not None and arm is not None
    m = unicorn.Uc(unicorn.UC_ARCH_ARM64, unicorn.UC_MODE_ARM)
    m.mem_map(BASE, 0x1000000)
    m.reg_write(arm.UC_ARM64_REG_CPACR_EL1, 3 << 20)   # floating point on
    ctx = Ctx(m, others)
    profile.stubs(ctx)
    return m, ctx


def capped(host, scale, cap=1.0, write=True):
    """Run the cap with the stub: s11 (the 3D views' scale the frame function goes on with) and the pc it returns to"""
    m, ctx = machine_with_stubs()
    if write: m.mem_write(BASE + STATE + 0x10, struct.pack('<f', host))
    m.reg_write(arm.UC_ARM64_REG_S0, bits(scale))
    m.reg_write(arm.UC_ARM64_REG_S9, bits(cap))
    m.emu_start(BASE + CAP_SITE, BASE + CAP_SITE + 4, count=16)
    return single(m.reg_read(arm.UC_ARM64_REG_S11)), m.reg_read(arm.UC_ARM64_REG_PC), ctx


def handed_on(dynamic, controller):
    """Run the update's load of its scale with the stub: s0 (what the clamp to the dynamic resolution's limits gets next) and the pc it returns to"""
    m, ctx = machine_with_stubs()
    m.mem_write(BASE + STATE + 0x40, struct.pack('<I', dynamic))
    m.mem_write(BASE + OBJ + 0x238, struct.pack('<f', controller))
    m.reg_write(arm.UC_ARM64_REG_X23, BASE + OBJ)
    m.emu_start(BASE + HOLD_SITE, BASE + HOLD_SITE + 4, count=16)
    return single(m.reg_read(arm.UC_ARM64_REG_S0)), m.reg_read(arm.UC_ARM64_REG_PC), ctx


@unittest.skipIf(unicorn is None, 'optional ARM64 execution dependency: unicorn')
class RenderScale(unittest.TestCase):
    def test_sites_and_declarations(self):
        _, _, ctx = capped(1.0, 0.5)
        self.assertEqual(ctx.sites[CAP_SITE], '0b78291e')    # fminnm s11,s0,s9
        self.assertEqual(ctx.sites[HOLD_SITE], 'e03a42bd')   # ldr s0,[x23,#0x238]
        self.assertEqual(ctx.render_scale, 2)
        self.assertEqual(ctx.capabilities, {'DYNAMIC_RESOLUTION'})

    def test_one_or_unset_keeps_the_games_scale(self):
        for host, write in ((1.0, True), (0.0, True), (0.0, False)):
            for scale in (0.5, 0.75, 1.0):
                with self.subTest(host=host, write=write, scale=scale):
                    s11, pc, _ = capped(host, scale, write=write)
                    self.assertAlmostEqual(s11, scale, places=6)
                    self.assertEqual(pc, BASE + CAP_SITE + 4)

    def test_the_host_scale_multiplies_the_games_under_its_cap(self):
        for host, scale, want in ((1.5, 0.5, 0.75), (2.0, 0.5, 1.0), (0.5, 0.5, 0.25), (2.0, 0.75, 1.0), (1.25, 0.5, 0.625)):
            with self.subTest(host=host, scale=scale):
                s11, pc, _ = capped(host, scale)
                self.assertAlmostEqual(s11, want, places=6)   # 768x432 x 1.5 = 1152x648; 2.0 reaches the cap, 1536x864
                self.assertEqual(pc, BASE + CAP_SITE + 4)


@unittest.skipIf(unicorn is None, 'optional ARM64 execution dependency: unicorn')
class DynamicResolution(unittest.TestCase):
    def test_held_at_the_top_by_default(self):
        for controller in (0.5, 0.8, 1.07):
            with self.subTest(controller=controller):
                s0, pc, _ = handed_on(0, controller)
                self.assertEqual(s0, 1.0)   # the clamp after the site turns it into render.dynres_max_scale_x
                self.assertEqual(pc, BASE + HOLD_SITE + 4)

    def test_on_hands_on_the_controllers_scale(self):
        for controller in (0.5, 0.8, 1.07):
            with self.subTest(controller=controller):
                s0, pc, _ = handed_on(1, controller)
                self.assertAlmostEqual(s0, controller, places=6)
                self.assertEqual(pc, BASE + HOLD_SITE + 4)

    def test_without_the_update_only_the_render_scale_is_placed(self):
        m, ctx = machine_with_stubs(others=False)
        self.assertEqual(set(ctx.sites), {CAP_SITE})
        self.assertEqual(ctx.capabilities, set())


if __name__ == '__main__':
    unittest.main()
