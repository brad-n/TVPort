# Star Fox (0400E88025B1A000): the rewriter's patches of this game's own code. dm/tools/patch_nso.py loads every profile's patches.py;
# MATCH_FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
from nso_asm import ADRP, B, CBNZW


def bcond(frm, to, cond):   # b.<cond> (0 eq, 0xd le)
    off = to - frm
    assert -(1 << 20) <= off < (1 << 20) and off % 4 == 0
    return 0x54000000 | (((off >> 2) & 0x7FFFF) << 5) | cond


# The 3D views' size, docked (v131072; found by fingerprint, so the addresses are only for reading). Once a frame the renderer's frame function (main+0xb447300) reads the cvar
# render.resolution_scale (0.5 docked here: 768x432, from the game's own data) or, when it is not zero, render.resolution_scale_console ("Nintendo only"; _handheld in handheld mode), and takes
# min(scale, [x25+0x66c]) (1.0) at main+0xb4498e4 (fminnm s11,s0,s9). The upscaler's output is 0.8 of the display (1536x864 on a 1920x1080 one: the host answers the display's size
# docked, as a Switch 2 does, hle_vi.c) and the 3D views are that times the scale: 768x432 at 0.5, 1536x864 at 1.0. The game's dynamic resolution then works within 0.5 to 1.0 of
# those views and stays at the top on the Mac (its controller, main+0xb45ae40, reads the GPU time right: README, The picture). The stub multiplies the scale by the host's render
# scale (state +0x10, DM_RENDER_SCALE, written by the loader) before the game's own cap: 2.0 gives 1536x864, 1.5 1152x648. 1.0, or none written, runs the original.
# s0 is the scale on every path to the site, and s1, s2 and x16 are dead after it (no path reads them before writing them), so nothing is saved
def render_scale(ctx):
    here, emit = ctx.here, ctx.emit
    site = ctx.base + 0x25e4
    ctx.site(site, '0b78291e')   # fminnm s11,s0,s9
    start = here()
    emit(ADRP(16, here(), ctx.state))
    emit(0xbd401201)   # ldr s1,[x16,#0x10]     render scale
    emit(0x1e2e1002)   # fmov s2,#1.0
    emit(0x1e222020)   # fcmp s1,s2
    orig = start + 4 * 8   # word 8 of the stub: the original instruction
    emit(bcond(here(), orig, 0x0))   # 1.0: the game's own scale
    emit(0x1e202028)   # fcmp s1,#0.0
    emit(bcond(here(), orig, 0xd))   # none written
    emit(0x1e210800)   # fmul s0,s0,s1          the game's scale times the host's
    emit(0x1e29780b)   # fminnm s11,s0,s9       the original: the game's cap (1.0, the upscaler's output size)
    emit(B(here(), site + 4))
    ctx.put(site, [B(site, start)], '3D view scale = the game\'s resolution scale times the host render scale (state +0x10; 1.0 = the game\'s own)')
    ctx.render_scale = 2   # 0.5 x 2.0 reaches the game's cap, 1.0: 1536x864 on a 1080p display


# Dynamic resolution (the update main+0xb45ae40: mode 1, a proportional controller that scales the last 16 frames' sizes by the square root of the GPU budget over their GPU
# time, every 8 frames). On the Mac its output sits above 1.0 and is clamped to the top (render.dynres_max_scale_x 1.0), but in heavier scenes (the 30 fps cinematics) it can
# dip. Unless state +0x40 says the game's own may run (DM_DYNAMIC_RESOLUTION=1), the stub gives the scale it hands on, [x23+0x238] at +0xafc (ldr s0,[x23,#0x238]), as 1.0, which
# the clamp after it turns into the top: a fixed size, the render scale's. Its controller and history keep running untouched. x16 and x17 are dead after the site
def dynamic_resolution(ctx):
    base = ctx.others.get('dynamic resolution update')
    if base is None: return   # not found in this build (a red line from the locator): the game's own dynamic resolution
    here, emit = ctx.here, ctx.emit
    site = base + 0xafc
    ctx.site(site, 'e03a42bd')   # ldr s0,[x23,#0x238]
    start = here()
    emit(0xbd423ae0)   # ldr s0,[x23,#0x238]    the original: the controller's scale
    emit(ADRP(16, here(), ctx.state))
    emit(0xb9404211)   # ldr w17,[x16,#0x40]    1 = the game's own dynamic resolution
    back = start + 4 * 5   # word 5 of the stub: the way back
    emit(CBNZW(17, here(), back))
    emit(0x1e2e1000)   # fmov s0,#1.0           the top, after the clamp
    emit(B(here(), site + 4))
    ctx.put(site, [B(site, start)], 'dynamic resolution held at its top, or with state +0x40 (DM_DYNAMIC_RESOLUTION) the game\'s own controller')
    ctx.capabilities.add('DYNAMIC_RESOLUTION')


def stubs(ctx):
    render_scale(ctx)
    dynamic_resolution(ctx)


MATCH_FRAME_STEP = {'main': [
    {'name': '3D view scale and dynamic resolution from the host', 'size': 0x744c, 'fingerprints': ['150c560bd68fa941dbf939926acaf93203cc408966cda9700bda32aa586bf5ce'], 'stub': stubs,   # v131072 main+0xb447300
     'others': {'dynamic resolution update': {'size': 0xb1c, 'fingerprints': ['057e7efe50485b93f73f182501a146f9ad9b376c883eb107bbaca0a5ef8bb170']}}},   # main+0xb45ae40
]}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md)
BINDING = [
    {'what': '3D view scale: the game\'s resolution scale times the host render scale (DM_RENDER_SCALE)', 'now': 'game', 'goal': 'game', 'purpose': 'rendering',
     'why': "the game's own resolution scale where its frame function caps it, found by that function's fingerprint on any build that keeps it; switchable, 1.0 the game's own",
     'checked': 'v131072 main: one function with this fingerprint; the cvar reads, the cap and the dead registers read by disassembly; 768x432 at the default, and the cvar override at 0.75 and 1.0 gave 1152x648 and 1536x864 3D views on the Mac (2026-11-13)'},
    {'what': 'dynamic resolution: held at its top, or the game\'s own controller (DM_DYNAMIC_RESOLUTION)', 'now': 'game', 'goal': 'game', 'purpose': 'rendering',
     'why': "the scale the game's dynamic-resolution update hands on, found by the update's fingerprint on any build that keeps it; switchable",
     'checked': 'v131072 main: one function with this fingerprint; its mode, budget, GPU time and output read in play with probes (mode 1, 15 ms budget, 13 ms read, output 1.07 to 1.13 clamped to 1.0) (2026-11-13)'},
]
