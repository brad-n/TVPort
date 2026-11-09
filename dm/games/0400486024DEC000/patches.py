"""Ocarina v131072's build-checked real-time speed and render scale."""
from nso_asm import ADRP, B, BEQ


def CBZ_W(frm, to, rt):
    off = to - frm
    assert -(1 << 20) <= off < (1 << 20) and off % 4 == 0
    return 0x34000000 | (((off >> 2) & 0x7FFFF) << 5) | rt


def CBNZ_W(frm, to, rt):
    return CBZ_W(frm, to, rt) | 0x01000000


# Real-time speed. The frame loop (main+0x6e6be0) computes each frame's step as a constant over its target frame rate and never reads the clock: s1 is 60, or 30 in one mode of the game
# (the fcsel at main+0x6e6cc0), s0 the target, so one frame is one step however long it took and everything runs slowly below the target. Found by gunvalk (zortos293/Lichii PR #216).
# The stub keeps that division and takes the larger of it and s1 x the measured frame time (state +0x38, float seconds, hle_nvn.c): 0 there leaves the game's own step, and the step is
# never below it. It marks state +0x3c so the host measures only for a main that reads the value. x16, x17 and s0 are not read again before they are written after the site
def real_speed(ctx):
    here, emit = ctx.here, ctx.emit
    ctx.site(0x6e6cc4, '2818201e')
    start = here()
    emit(0x1e201828)                       # fdiv s8,s1,s0        the game's own step
    emit(ADRP(16, here(), ctx.state))
    for w in (0x52800031,   # mov w17,#1
              0xb9003e11,   # str w17,[x16,#0x3c]  this main reads the frame time
              0xbd403a00,   # ldr s0,[x16,#0x38]   seconds; 0 = at the target
              0x1e210800,   # fmul s0,s0,s1
              0x1e204908):  # fmax s8,s8,s0
        emit(w)
    emit(B(here(), 0x6e6cc8))
    ctx.put(0x6e6cc4, [B(0x6e6cc4, start)], 'frame step from the measured frame time, never below the game\'s own (state +0x38)')
    # Render scale (state +0x10, float written by the loader: DM_RENDER_SCALE, 1.0 by default; independent of the frame step). The dynamic-resolution controller (main+0x805aa0: its
    # levels, counters and LoadThreshold come from game__gfx__DynamicResolutionParam; the cost model main+0x8065e0, the level-to-ratio getter main+0x31c3fe0) returns a status byte
    # (bits 32-39 of x0: 0 = a new scale, 1 = another request, 2 = unchanged) and its ratio (the low word) to the graphics module's frame update (main+0x31d3200). Status 0 sets
    # bit 3 of [module+0xe2c]; with it set (or in the game's forced 0.75 / 0.5 modes, [module+0xe20] & 0x18) the update turns the ratio into the 3D views' scale, [module+0xe5c] =
    # [+0xe58] x ratio / [+0xe50] (main+0x31d3f38-0x31d3f48, the only store to it), and sizes every view from it (main+0x31d3df0, main+0x31d3fd8); other readers: main+0x1657a8,
    # main+0x474cc4, main+0x6fb744, main+0x2b872c4. Two stubs. At the join of the ratio's sources (main+0x31d3f38) a factor replaces the ratio (s0), so the scale is the factor whatever
    # the controller picks, and +0x14 records that it was applied. At the status (main+0x31d3ee4) a factor not yet applied turns status 0 or 2 into 0 once, so the first frame computes the
    # sizes (at a steady frame rate the controller never answers 0); status 1 is left alone. After that the controller's levels change nothing: the sizes, and the render targets, hold.
    # 1.0 or unset runs the original. x16 and x17 appear nowhere in main+0x31d3200..0x31d41d0, and the flags are dead at the status site (a cmp follows), so nothing is saved.
    # The same function and store were found independently by upstream PR 1903 (seedds/nxnative), which multiplies at the store instead and drives the level getter to the top level
    ctx.site(0x31d3ee4, '089c60d3')
    start = here()
    emit(0xd3609c08)   # ubfx x8,x0,#32,#8      the original: the status byte
    emit(ADRP(16, here(), ctx.state))
    for w in (0xb9401211,   # ldr w17,[x16,#0x10]     render scale (float bits)
              0xb9401610,   # ldr w16,[x16,#0x14]     the scale the join stub applied
              0x6b11021f):  # cmp w16,w17
        emit(w)
    done = here() + 4 * 7   # word 12 of this stub
    emit(BEQ(here(), done))   # applied already
    emit(CBZ_W(here(), done, 17))   # not set
    emit(0x52091a30)   # eor w16,w17,#0x3f800000
    emit(CBZ_W(here(), done, 16))   # 1.0: the game's own
    emit(0x7100051f)   # cmp w8,#1
    emit(BEQ(here(), done))   # status 1 is the game's other request: left alone
    emit(0x52800008)   # mov w8,#0              a new scale: the sizes are computed this frame
    assert here() == done
    emit(B(here(), 0x31d3ee8))
    ctx.put(0x31d3ee4, [B(0x31d3ee4, start)], 'dynamic-resolution status: a host render scale not yet applied asks for new 3D sizes once')
    ctx.site(0x31d3f38, '815a4ebd')
    start = here()
    emit(ADRP(16, here(), ctx.state))
    emit(0xb9401211)   # ldr w17,[x16,#0x10]     render scale (float bits)
    orig = here() + 4 * 5
    emit(CBZ_W(here(), orig, 17))   # not set
    emit(0xb9001611)   # str w17,[x16,#0x14]     applied (the status stub's test)
    emit(0x52091a30)   # eor w16,w17,#0x3f800000
    emit(CBZ_W(here(), orig, 16))   # 1.0: the game's own ratio
    emit(0x1e270220)   # fmov s0,w17             the host's scale instead of the controller's ratio
    assert here() == orig
    emit(0xbd4e5a81)   # ldr s1,[x20,#0xe58]     the original
    emit(B(here(), 0x31d3f3c))
    ctx.put(0x31d3f38, [B(0x31d3f38, start)], 'view scale = the host render scale (1.0 = the game\'s dynamic resolution)')
    ctx.render_scale = 1
    # Static shadow map size (state +0xa0, u32 pixels written by the loader: DM_SHADOW_MAP_SIZE, 0 = the game's). The game keeps two depth textures (format 0x5a, Depth16) for its static
    # depth shadows, the samplers cSamplerFineStaticDepthShadow / cSamplerCoarseStaticDepthShadow: a fine one of 12288x12288 (296 MB of the graphics memory on tvOS) and a coarse one of
    # 4096x4096. Both sizes are literals, not the StaticSdwWidth parameter (4096 in Main.gsys__ModelSceneConfigParam, read into the config at +0x548). The fine one is made at
    # main+0xc30c24 / main+0xc30c2c (width and height of the texture info of the function at main+0xc30870) and once more at main+0x344d78 (the call main+0xc2f3f0, which makes a render
    # target of one size for both sides); the stubs put the host's size in place of the literal, so the game itself allocates the smaller texture and sizes its viewports from it. Each
    # stub clobbers only the register the displaced mov wrote. No other 0x3000 / 12288.0 / 1/12288 literal belongs to the map (searched in the whole of main's code)
    for site, rd in ((0xc30c24, 3), (0xc30c2c, 4), (0x344d78, 3)):
        ctx.site(site, (0x52860000 | rd).to_bytes(4, 'little').hex())   # mov wN,#0x3000
        start = here()
        emit(ADRP(rd, here(), ctx.state))
        emit(0xb940a000 | (rd << 5) | rd)   # ldr wN,[xN,#0xa0]     the host's size
        emit(CBNZ_W(here(), here() + 8, rd))   # set: keep it
        emit(0x52860000 | rd)   # mov wN,#0x3000        the game's own
        emit(B(here(), site + 4))
        ctx.put(site, [B(site, start)], 'static shadow map size = the host size (0 = the game\'s 12288)')


FRAME_STEP = {'e0f3ccfaf50065ae4ea01eb5aeb13b1a': real_speed}   # 1.1.1 (v131072), the main of v0 too

BINDING = [
    {'what': 'frame step from the measured frame time', 'now': 'build', 'goal': 'game', 'purpose': 'frame rate',
     'why': "this game's own frame loop; the frame-step state page is general",
     'blocked': 'frame-step stubs have no function-matched form yet'},
]
