"""Ocarina v131072's build-checked real-time speed and render scale."""
from nso_asm import ADRP, B


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
    # Render scale (state +0x10, float written by the loader: DM_RENDER_SCALE, 1.0 by default; independent of the frame step). The dynamic-resolution controller (main+0x805aa0, its
    # level lists and thresholds read from game__gfx__DynamicResolutionParam; the cost model main+0x8065e0, the level-to-ratio getter main+0x31c3fe0) returns its ratio in the low word
    # of x0 to the graphics module's frame update (main+0x31d3200), which turns it into the 3D views' scale: [module+0xe5c] = [+0xe58] x ratio / [+0xe50] at main+0x31d3f38, stored
    # nowhere else and read by the view-size code (main+0x31d3df0, main+0x31d3fd8) and by the readers at main+0x1657a8, main+0x474cc4, main+0x6fb744, main+0x2b872c4. The game's
    # forced 0.75 / 0.5 modes ([module+0xe20] & 0x18) join at the same instruction, so one site covers every source of the ratio: with a factor, s0 (the ratio) is replaced by it, the
    # scale is fixed and the levels the controller picks no longer change a size (nor move a render target). 1.0 or unset runs the original. x16 and x17 appear nowhere in the
    # function (main+0x31d3200 to 0x31d41d0), so both are free; s0 is dead until the fmul that follows
    ctx.site(0x31d3f38, '815a4ebd')
    start = here()
    emit(ADRP(16, here(), ctx.state))
    for w in (0xb9401211,   # ldr w17,[x16,#0x10]     render scale (float bits)
              0x34000091,   # cbz w17,orig (+4)        not set
              0x52091a30,   # eor w16,w17,#0x3f800000
              0x34000050,   # cbz w16,orig (+2)        1.0: the game's own ratio
              0x1e270220,   # fmov s0,w17              the host's scale instead of the controller's ratio
              0xbd4e5a81):  # orig: ldr s1,[x20,#0xe58]
        emit(w)
    emit(B(here(), 0x31d3f3c))
    ctx.put(0x31d3f38, [B(0x31d3f38, start)], 'view scale = the host render scale (1.0 = the game\'s dynamic resolution)')
    ctx.render_scale = 1


FRAME_STEP = {'e0f3ccfaf50065ae4ea01eb5aeb13b1a': real_speed}   # 1.1.1 (v131072), the main of v0 too

BINDING = [
    {'what': 'frame step from the measured frame time', 'now': 'build', 'goal': 'game', 'purpose': 'frame rate',
     'why': "this game's own frame loop; the frame-step state page is general",
     'blocked': 'frame-step stubs have no function-matched form yet'},
]
