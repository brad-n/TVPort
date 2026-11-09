"""Execute Ocarina's emitted stubs: the frame step (the game's step, or the measured one when that is longer) and the render scale (the 3D views' scale from the host) and the static shadow map size (the literal 12288 of its texture from the host)."""
import importlib
import importlib.util
from pathlib import Path
import struct
import sys
import unittest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools'))

spec = importlib.util.spec_from_file_location('oot_speed', REPO / 'dm/games/0400486024DEC000/patches.py')
assert spec is not None and spec.loader is not None
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
try:
    unicorn = importlib.import_module('unicorn')
    arm = importlib.import_module('unicorn.arm64_const')
except ImportError:
    unicorn = arm = None

BASE, AREA, STATE, SITE = 0x4000000, 0x800000, 0x900000, 0x6e6cc4
STATUS_SITE, SCALE_SITE, MODULE = 0x31d3ee4, 0x31d3f38, 0x3300000   # the graphics module's frame update joins here; MODULE stands for x20


class Ctx:
    state = STATE

    def __init__(self, machine):
        self.machine, self.cursor, self.sites = machine, AREA, {}

    def here(self):
        return self.cursor

    def emit(self, word):
        self.machine.mem_write(BASE + self.cursor, struct.pack('<I', word))
        self.cursor += 4

    def site(self, offset, original):
        self.sites[offset] = original

    def put(self, offset, words, reason):
        self.machine.mem_write(BASE + offset, b''.join(struct.pack('<I', w) for w in words))


def float_reg(value):
    return struct.unpack('<I', struct.pack('<f', value))[0]


def run(constant, target, seconds):
    assert unicorn is not None and arm is not None
    machine = unicorn.Uc(unicorn.UC_ARCH_ARM64, unicorn.UC_MODE_ARM)
    machine.mem_map(BASE, 0x3400000)
    machine.reg_write(arm.UC_ARM64_REG_CPACR_EL1, 3 << 20)   # the FP unit is off at reset
    ctx = Ctx(machine)
    profile.real_speed(ctx)
    machine.mem_write(BASE + STATE + 0x38, struct.pack('<f', seconds))
    machine.reg_write(arm.UC_ARM64_REG_S1, float_reg(constant))
    machine.reg_write(arm.UC_ARM64_REG_S0, float_reg(target))
    machine.emu_start(BASE + SITE, BASE + SITE + 4, count=16)
    step = struct.unpack('<f', struct.pack('<I', machine.reg_read(arm.UC_ARM64_REG_S8) & 0xffffffff))[0]
    mark = struct.unpack('<I', machine.mem_read(BASE + STATE + 0x3c, 4))[0]
    return step, mark, ctx, machine.reg_read(arm.UC_ARM64_REG_PC)


def scaled(host, ratio, applied=0.0):
    """Run the render scale stub from its site to the instruction after it: the scale it leaves in s0 (the ratio the controller returned, or the host's) and the s1 it loads."""
    assert unicorn is not None and arm is not None
    machine = unicorn.Uc(unicorn.UC_ARCH_ARM64, unicorn.UC_MODE_ARM)
    machine.mem_map(BASE, 0x3400000)
    machine.reg_write(arm.UC_ARM64_REG_CPACR_EL1, 3 << 20)
    ctx = Ctx(machine)
    profile.real_speed(ctx)
    machine.mem_write(BASE + STATE + 0x10, struct.pack('<f', host))
    machine.mem_write(BASE + STATE + 0x14, struct.pack('<f', applied))
    machine.mem_write(BASE + MODULE + 0xe58, struct.pack('<f', 1536.0))
    machine.reg_write(arm.UC_ARM64_REG_X20, BASE + MODULE)
    machine.reg_write(arm.UC_ARM64_REG_S0, float_reg(ratio))
    machine.reg_write(arm.UC_ARM64_REG_S1, float_reg(7.0))
    machine.emu_start(BASE + SCALE_SITE, BASE + SCALE_SITE + 4, count=16)
    out = [struct.unpack('<f', struct.pack('<I', machine.reg_read(r) & 0xffffffff))[0] for r in (arm.UC_ARM64_REG_S0, arm.UC_ARM64_REG_S1)]
    return out, ctx, machine.reg_read(arm.UC_ARM64_REG_PC), struct.unpack('<f', machine.mem_read(BASE + STATE + 0x14, 4))[0]


def status(host, applied, status_byte):
    """Run the status stub: the status byte (w8) it leaves for the frame update."""
    assert unicorn is not None and arm is not None
    machine = unicorn.Uc(unicorn.UC_ARCH_ARM64, unicorn.UC_MODE_ARM)
    machine.mem_map(BASE, 0x3400000)
    ctx = Ctx(machine)
    profile.real_speed(ctx)
    machine.mem_write(BASE + STATE + 0x10, struct.pack('<f', host))
    machine.mem_write(BASE + STATE + 0x14, struct.pack('<f', applied))
    machine.reg_write(arm.UC_ARM64_REG_X0, (status_byte << 32) | 0x3f000000)
    machine.emu_start(BASE + STATUS_SITE, BASE + STATUS_SITE + 4, count=32)
    return machine.reg_read(arm.UC_ARM64_REG_X8), ctx, machine.reg_read(arm.UC_ARM64_REG_PC)


@unittest.skipIf(unicorn is None, 'optional ARM64 execution dependency: unicorn')
class RenderScale(unittest.TestCase):
    def test_the_site_is_the_join_of_the_dynamic_and_forced_ratios(self):
        ctx = scaled(1.0, 0.6)[1]
        self.assertEqual(ctx.sites[SCALE_SITE], '815a4ebd')   # ldr s1,[x20,#0xe58]
        self.assertEqual(ctx.sites[STATUS_SITE], '089c60d3')   # ubfx x8,x0,#32,#8
        self.assertEqual(ctx.render_scale, 1)

    def test_one_or_unset_keeps_the_controllers_ratio(self):
        for host in (1.0, 0.0):
            with self.subTest(host=host):
                (s0, s1), _, pc, _ = scaled(host, 0.6)
                self.assertAlmostEqual(s0, 0.6, places=6)
                self.assertEqual(s1, 1536.0)   # the displaced load ran
                self.assertEqual(pc, BASE + SCALE_SITE + 4)

    def test_a_factor_replaces_the_ratio(self):
        for host in (0.5, 0.75, 0.9):
            for ratio in (0.5, 0.6, 1.0, 1.03):
                with self.subTest(host=host, ratio=ratio):
                    (s0, s1), _, pc, _ = scaled(host, ratio)
                    self.assertAlmostEqual(s0, host, places=6)
                    self.assertEqual(s1, 1536.0)
                    self.assertEqual(pc, BASE + SCALE_SITE + 4)

    def test_the_join_records_the_applied_scale(self):
        self.assertAlmostEqual(scaled(0.75, 0.6)[3], 0.75, places=6)
        self.assertEqual(scaled(1.0, 0.6)[3], 1.0)   # recorded too, harmless: the status stub treats 1.0 as the game's own
        self.assertEqual(scaled(0.0, 0.6)[3], 0.0)

    def test_a_scale_not_yet_applied_makes_status_zero_once(self):
        for status_byte in (0, 2):
            with self.subTest(status=status_byte):
                got, _, pc = status(0.75, 0.0, status_byte)
                self.assertEqual(got, 0)
                self.assertEqual(pc, BASE + STATUS_SITE + 4)
        self.assertEqual(status(0.75, 0.75, 2)[0], 2)   # applied: the controller's status stands

    def test_status_one_and_the_games_own_scale_are_left_alone(self):
        self.assertEqual(status(0.75, 0.0, 1)[0], 1)
        for host in (1.0, 0.0):
            for status_byte in (0, 1, 2):
                with self.subTest(host=host, status=status_byte):
                    self.assertEqual(status(host, 0.0, status_byte)[0], status_byte)


SHADOW_SITES = {0xc30c24: 3, 0xc30c2c: 4, 0x344d78: 3}   # mov w3 / w4,#0x3000: the fine static depth shadow texture's width and height, and the render target call


def shadow_size(site, host, canary=0x5a5a5a5a5a5a5a5a):
    """Run the stub of one static shadow map site: the register it leaves, whether the others are untouched, and where it goes on."""
    assert unicorn is not None and arm is not None
    machine = unicorn.Uc(unicorn.UC_ARCH_ARM64, unicorn.UC_MODE_ARM)
    machine.mem_map(BASE, 0x3400000)
    ctx = Ctx(machine)
    profile.real_speed(ctx)
    machine.mem_write(BASE + STATE + 0xa0, struct.pack('<I', host))
    rd = SHADOW_SITES[site]
    others = [r for r in range(0, 8) if r != rd]
    for r in others:
        machine.reg_write(arm.UC_ARM64_REG_X0 + r, canary + r)
    machine.reg_write(arm.UC_ARM64_REG_X16, canary)
    machine.reg_write(arm.UC_ARM64_REG_X17, canary)
    machine.emu_start(BASE + site, BASE + site + 4, count=16)
    kept = all(machine.reg_read(arm.UC_ARM64_REG_X0 + r) == canary + r for r in others) and machine.reg_read(arm.UC_ARM64_REG_X16) == canary
    return machine.reg_read(arm.UC_ARM64_REG_X0 + rd), kept, ctx, machine.reg_read(arm.UC_ARM64_REG_PC)


@unittest.skipIf(unicorn is None, 'optional ARM64 execution dependency: unicorn')
class ShadowMapSize(unittest.TestCase):
    def test_the_sites_are_the_literals_of_the_fine_shadow_texture(self):
        ctx = shadow_size(0xc30c24, 0)[2]
        for site, rd in SHADOW_SITES.items():
            self.assertEqual(ctx.sites[site], (0x52860000 | rd).to_bytes(4, 'little').hex())   # mov wN,#0x3000

    def test_unset_keeps_the_games_12288(self):
        for site in SHADOW_SITES:
            with self.subTest(site=hex(site)):
                got, kept, _, pc = shadow_size(site, 0)
                self.assertEqual(got, 12288)
                self.assertTrue(kept)
                self.assertEqual(pc, BASE + site + 4)

    def test_a_size_replaces_it(self):
        for site in SHADOW_SITES:
            for size in (4096, 6144, 8192):
                with self.subTest(site=hex(site), size=size):
                    got, kept, _, pc = shadow_size(site, size)
                    self.assertEqual(got, size)
                    self.assertTrue(kept)   # only the displaced mov's register changes: no scratch register is taken
                    self.assertEqual(pc, BASE + site + 4)

    def test_the_width_and_height_stay_equal(self):
        self.assertEqual(shadow_size(0xc30c24, 6144)[0], shadow_size(0xc30c2c, 6144)[0])


@unittest.skipIf(unicorn is None, 'optional ARM64 execution dependency: unicorn')
class RealSpeed(unittest.TestCase):
    def test_registered_build(self):
        self.assertEqual(profile.FRAME_STEP, {'e0f3ccfaf50065ae4ea01eb5aeb13b1a': profile.real_speed})

    def test_no_measurement_keeps_the_games_step(self):
        step, mark, ctx, pc = run(60.0, 60.0, 0.0)
        self.assertEqual(step, 1.0)
        self.assertEqual(mark, 1)
        self.assertEqual(ctx.sites[SITE], '2818201e')
        self.assertEqual(pc, BASE + SITE + 4)

    def test_a_slow_frame_steps_by_its_time(self):
        self.assertAlmostEqual(run(60.0, 60.0, 0.05)[0], 3.0, places=5)
        self.assertAlmostEqual(run(30.0, 30.0, 0.1)[0], 3.0, places=5)

    def test_never_below_the_games_step(self):
        self.assertEqual(run(60.0, 60.0, 0.001)[0], 1.0)


if __name__ == '__main__':
    unittest.main()
