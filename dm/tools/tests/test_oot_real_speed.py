"""Execute Ocarina's render scale, static shadow map size, reflection probe interval, ground mist and foliage stubs (the 3D views' scale and the literal 12288 of the shadow texture from the host). The frame step is upstream's function-matched stub (MATCH_FRAME_STEP), which calls them; the real-speed stub it replaced is gone."""
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
    base = 0x6e6be0   # the matched function's start in v131072
    render_scale = 0

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


def scaled(host, ratio, applied=0.0):
    """Run the render scale stub from its site to the instruction after it: the scale it leaves in s0 (the ratio the controller returned, or the host's) and the s1 it loads."""
    assert unicorn is not None and arm is not None
    machine = unicorn.Uc(unicorn.UC_ARCH_ARM64, unicorn.UC_MODE_ARM)
    machine.mem_map(BASE, 0x3400000)
    machine.reg_write(arm.UC_ARM64_REG_CPACR_EL1, 3 << 20)
    ctx = Ctx(machine)
    profile.render_scale(ctx)
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
    profile.render_scale(ctx)
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
    profile.shadow_map(ctx)
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


PROBE_SCHEDULER, FLUID_DRAW = 0x33d6a0, 0x26b110   # v131072: the cube map scheduler and the fluid volumes' draw (others of the frame step rule)
PROBE_SITE, MIST_SITE = PROBE_SCHEDULER + 0x90, FLUID_DRAW + 0x24
SCHEDULER, FLUID_DRAWER = 0x3300000, 0x3380000   # stand for x19 (the scheduler) and x0 (the fluid drawer)


def quality_ctx(machine):
    ctx = Ctx(machine)
    ctx.others, ctx.capabilities = {'probe scheduler': PROBE_SCHEDULER, 'fluid draw': FLUID_DRAW}, set()
    return ctx


def probe_budget(interval, frame, budget=3, canary=0x5a5a5a5a5a5a5a5a):
    """Run the reflection probe stub from its site to the instruction after it: the face budget it leaves in w10 for this frame, whether the registers it may not touch kept
    their values, and where it goes on"""
    assert unicorn is not None and arm is not None
    machine = unicorn.Uc(unicorn.UC_ARCH_ARM64, unicorn.UC_MODE_ARM)
    machine.mem_map(BASE, 0x3400000)
    ctx = quality_ctx(machine)
    profile.probe_interval(ctx)
    machine.mem_write(BASE + STATE + 0xa8, struct.pack('<I', interval))
    machine.mem_write(BASE + STATE + 0xac, struct.pack('<I', frame))
    machine.mem_write(BASE + SCHEDULER + 0x268, struct.pack('<I', budget))
    kept = [r for r in range(29) if r not in (9, 10, 16, 17, 19)]   # w9 is dead at the site (the next instruction loads it), w10 is the result, x16 / x17 are free in the function
    for r in kept: machine.reg_write(arm.UC_ARM64_REG_X0 + r, canary + r)
    machine.reg_write(arm.UC_ARM64_REG_X19, BASE + SCHEDULER)
    machine.emu_start(BASE + PROBE_SITE, BASE + PROBE_SITE + 4, count=32)
    ok = all(machine.reg_read(arm.UC_ARM64_REG_X0 + r) == canary + r for r in kept)
    return machine.reg_read(arm.UC_ARM64_REG_X10), ok, ctx, machine.reg_read(arm.UC_ARM64_REG_PC)


@unittest.skipIf(unicorn is None, 'optional ARM64 execution dependency: unicorn')
class ReflectionInterval(unittest.TestCase):
    def test_the_site_is_the_schedulers_face_budget(self):
        ctx = probe_budget(0, 0)[2]
        self.assertEqual(ctx.sites[PROBE_SITE], '6a6a42b9')   # ldr w10,[x19,#0x268]
        self.assertIn('REFLECTION_INTERVAL', ctx.capabilities)

    def test_unset_and_one_keep_the_games_budget_every_frame(self):
        for interval in (0, 1):
            for frame in range(6):
                with self.subTest(interval=interval, frame=frame):
                    budget, ok, _, pc = probe_budget(interval, frame)
                    self.assertEqual(budget, 3)
                    self.assertTrue(ok)
                    self.assertEqual(pc, BASE + PROBE_SITE + 4)

    def test_an_interval_gives_the_budget_on_every_nth_frame_only(self):
        for interval in (2, 3, 4, 8):
            for frame in list(range(2 * interval + 1)) + [0xffffffff, 0xfffffff8]:
                with self.subTest(interval=interval, frame=frame):
                    budget, ok, _, pc = probe_budget(interval, frame)
                    self.assertEqual(budget, 3 if frame % interval == 0 else 0)
                    self.assertTrue(ok)
                    self.assertEqual(pc, BASE + PROBE_SITE + 4)


def mist_enabled(setting, enabled=1, canary=0x5a5a5a5a5a5a5a5a):
    """Run the ground mist stub from its site to the instruction after it: the enabled byte it leaves in w8 (the draw function returns at once unless it is 1)"""
    assert unicorn is not None and arm is not None
    machine = unicorn.Uc(unicorn.UC_ARCH_ARM64, unicorn.UC_MODE_ARM)
    machine.mem_map(BASE, 0x3400000)
    ctx = quality_ctx(machine)
    profile.ground_mist(ctx)
    machine.mem_write(BASE + STATE + 0xa4, struct.pack('<I', setting))
    machine.mem_write(BASE + FLUID_DRAWER + 0x18, bytes([enabled]))
    kept = [r for r in range(1, 29) if r not in (8, 16, 17)]
    for r in kept: machine.reg_write(arm.UC_ARM64_REG_X0 + r, canary + r)
    machine.reg_write(arm.UC_ARM64_REG_X0, BASE + FLUID_DRAWER)
    machine.emu_start(BASE + MIST_SITE, BASE + MIST_SITE + 4, count=16)
    ok = all(machine.reg_read(arm.UC_ARM64_REG_X0 + r) == canary + r for r in kept) and machine.reg_read(arm.UC_ARM64_REG_X0) == BASE + FLUID_DRAWER
    return machine.reg_read(arm.UC_ARM64_REG_X8), ok, ctx, machine.reg_read(arm.UC_ARM64_REG_PC)


@unittest.skipIf(unicorn is None, 'optional ARM64 execution dependency: unicorn')
class GroundMist(unittest.TestCase):
    def test_the_site_is_the_fluid_drawers_enabled_byte(self):
        ctx = mist_enabled(0)[2]
        self.assertEqual(ctx.sites[MIST_SITE], '08604039')   # ldrb w8,[x0,#0x18]
        self.assertIn('GROUND_MIST', ctx.capabilities)

    def test_unset_keeps_the_drawers_own_state(self):
        for enabled in (0, 1):
            with self.subTest(enabled=enabled):
                got, ok, _, pc = mist_enabled(0, enabled)
                self.assertEqual(got, enabled)
                self.assertTrue(ok)
                self.assertEqual(pc, BASE + MIST_SITE + 4)

    def test_off_reads_as_disabled(self):
        for enabled in (0, 1):
            with self.subTest(enabled=enabled):
                got, ok, _, pc = mist_enabled(1, enabled)
                self.assertEqual(got, 0)
                self.assertTrue(ok)
                self.assertEqual(pc, BASE + MIST_SITE + 4)


FOLIAGE_CALC, FOLIAGE_MODULE = 0x2c00a40, 0x3200000   # v131072: the foliage module's per-frame calc (another of the frame step rule); stands for x0 (the module)


def foliage_flags(setting, grass=0, forest=0, word=0, flags=0x2008, canary=0x5a5a5a5a5a5a5a5a):
    """Run the foliage stub from its site to the instruction after it: the module's grass and forest bytes (+0x141 / +0x142) and debug word (+0x2b0) it leaves, the flags in w8
    (the original load), whether the registers it may not touch and the bytes around the fields kept their values, and where it goes on"""
    assert unicorn is not None and arm is not None
    machine = unicorn.Uc(unicorn.UC_ARCH_ARM64, unicorn.UC_MODE_ARM)
    machine.mem_map(BASE, 0x3400000)
    ctx = quality_ctx(machine)
    ctx.others['foliage calc'] = FOLIAGE_CALC
    profile.foliage(ctx)
    m = BASE + FOLIAGE_MODULE
    machine.mem_write(BASE + STATE + 0xb0, struct.pack('<I', setting))
    machine.mem_write(m + 0x30, struct.pack('<I', flags))
    machine.mem_write(m + 0x13c, bytes([0xa5] * 0x10))
    machine.mem_write(m + 0x141, bytes([grass, forest]))
    machine.mem_write(m + 0x2a8, bytes([0xa5] * 0x10))
    machine.mem_write(m + 0x2b0, struct.pack('<I', word))
    kept = [r for r in range(1, 29) if r not in (8, 9, 10, 11, 16, 17)]   # w8 is the original load's; x9..x11, x16 and x17 are free at the function's entry
    for r in kept: machine.reg_write(arm.UC_ARM64_REG_X0 + r, canary + r)
    machine.reg_write(arm.UC_ARM64_REG_X0, m)
    machine.emu_start(BASE + FOLIAGE_CALC, BASE + FOLIAGE_CALC + 4, count=32)
    ok = all(machine.reg_read(arm.UC_ARM64_REG_X0 + r) == canary + r for r in kept) and machine.reg_read(arm.UC_ARM64_REG_X0) == m
    around = bytes(machine.mem_read(m + 0x13c, 5)) + bytes(machine.mem_read(m + 0x143, 9)) + bytes(machine.mem_read(m + 0x2a8, 8)) + bytes(machine.mem_read(m + 0x2b4, 4))
    ok = ok and around == bytes([0xa5] * len(around))
    g, f = machine.mem_read(m + 0x141, 2)
    return g, f, struct.unpack('<I', machine.mem_read(m + 0x2b0, 4))[0], machine.reg_read(arm.UC_ARM64_REG_X8) & 0xffffffff, ok, ctx, machine.reg_read(arm.UC_ARM64_REG_PC)


@unittest.skipIf(unicorn is None, 'optional ARM64 execution dependency: unicorn')
class Foliage(unittest.TestCase):
    def test_the_site_is_the_calcs_flags_load(self):
        ctx = foliage_flags(0)[5]
        self.assertEqual(ctx.sites[FOLIAGE_CALC], '083040b9')   # ldr w8,[x0,#0x30]
        self.assertIn('FOLIAGE', ctx.capabilities)

    def test_unset_leaves_the_games_flags(self):
        for grass, forest, word in ((0, 0, 0), (1, 0, 0), (0, 1, 0x12345678), (1, 1, 0xffffffff)):
            with self.subTest(grass=grass, forest=forest, word=word):
                g, f, w, w8, ok, _, pc = foliage_flags(0, grass, forest, word)
                self.assertEqual((g, f, w, w8), (grass, forest, word, 0x2008))
                self.assertTrue(ok)
                self.assertEqual(pc, BASE + FOLIAGE_CALC + 4)

    def test_off_sets_the_grass_and_forest_disables_and_the_type_hide_bits(self):
        for grass, forest, word in ((0, 0, 0), (1, 0, 0x12345678), (0, 1, 0xffffffff)):
            with self.subTest(grass=grass, forest=forest, word=word):
                g, f, w, w8, ok, _, pc = foliage_flags(1, grass, forest, word)
                self.assertEqual((g, f, w, w8), (1, 1, word | 0xf00, 0x2008))
                self.assertTrue(ok)
                self.assertEqual(pc, BASE + FOLIAGE_CALC + 4)

    def test_two_turns_them_back_on(self):   # diagnostics only: the loader writes 0 or 1
        for grass, forest, word in ((1, 1, 0xf00), (1, 1, 0xffffffff)):
            with self.subTest(grass=grass, forest=forest, word=word):
                g, f, w, w8, ok, _, pc = foliage_flags(2, grass, forest, word)
                self.assertEqual((g, f, w, w8), (0, 0, word & ~0xf00, 0x2008))
                self.assertTrue(ok)
                self.assertEqual(pc, BASE + FOLIAGE_CALC + 4)


class MatchedFrameStep(unittest.TestCase):
    def test_render_scale_is_part_of_the_matched_stub_and_only_at_v131072_offsets(self):
        ctx = Ctx(None)
        ctx.base = 0x1000
        profile.render_scale(ctx)
        self.assertEqual((ctx.sites, ctx.render_scale), ({}, 0))
        ctx = Ctx(None)
        ctx.base = 0x1000
        profile.shadow_map(ctx)
        self.assertEqual(ctx.sites, {})

    def test_the_quality_stubs_need_their_functions(self):
        for stub in (profile.probe_interval, profile.ground_mist, profile.foliage):
            with self.subTest(stub=stub.__name__):
                ctx = Ctx(None)
                ctx.others, ctx.capabilities = {'probe scheduler': None, 'fluid draw': None, 'foliage calc': None}, set()
                stub(ctx)
                self.assertEqual((ctx.sites, ctx.capabilities), ({}, set()))

    def test_the_quality_stubs_functions_are_others_of_the_rule(self):
        others = profile.MATCH_FRAME_STEP['main'][0]['others']
        self.assertEqual(others['probe scheduler']['size'], 0xa84)
        self.assertEqual(others['fluid draw']['size'], 0x13f8)
        self.assertEqual(others['foliage calc']['size'], 0x6f8)

    def test_the_frame_step_is_matched_not_build_bound(self):
        self.assertFalse(hasattr(profile, 'FRAME_STEP'))
        self.assertIn('main', profile.MATCH_FRAME_STEP)


if __name__ == '__main__':
    unittest.main()
