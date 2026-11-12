# The Legend of Zelda: Ocarina of Time (0400486024DEC000): the rewriter's patches of this game's own code. dm/tools/patch_nso.py loads every profile's patches.py;
# MATCH_FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
from nso_asm import ADRP, B, BEQ


def cbz_w(frm, to, rt):
    off = to - frm
    assert -(1 << 20) <= off < (1 << 20) and off % 4 == 0
    return 0x34000000 | (((off >> 2) & 0x7FFFF) << 5) | rt

def cbnz_w(frm, to, rt):
    return cbz_w(frm, to, rt) | 0x01000000


# The game's frame ratio. Once a frame the function at main+0x6e6be0 (v131072) divides its base rate (60.0, or 30.0 while bit 0 of [x21+0x24f] is set) by the int frame rate at
# [x21+0x2c8] (fdiv s8,s1,s0 at +0xe4) and hands the result to the time object (main+0x3b4e300: ratio at +0x10, 1 / ratio at +0x14, round(60 / ratio) at +0x1c), which the game
# steps by; the frame's own time never enters it, so a frame that takes two vsyncs at rate 60 plays at half speed. The stub gives the ratio the host's step instead: step × base / 60
# (the division's value when the host keeps frames 60 / rate vsyncs), and counts the vsyncs stepped. Until the host has decided a step, and at fps_target 0, the division runs.
# s0 and x16 / x17 are free there (s0 is written again on every path before it is read; the function uses neither x16 nor x17); s1 keeps the base rate.
# Lichii (a GPL emulator; only the fact was taken) found the division (its notes: main+0x6E6CC4, 60 / [x21+0x2C8])
def frame_step(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF, base = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state, ctx.base
    site = base + 0xe4
    fs_site(site, '2818201e')   # fdiv s8,s1,s0
    start = here(); emit(ADRP(16, here(), FS_STATE_OFF))
    for w in (0xb9400211,   # ldr w17,[x16]          target fps (0 = off)
              0x340001b1,   # cbz w17,orig (+13)
              0xb9402211,   # ldr w17,[x16,#0x20]    step in vsyncs
              0x34000171,   # cbz w17,orig (+11)     not decided yet
              0x1e230220,   # ucvtf s0,w17
              0xf9401a10,   # ldr x16,[x16,#0x30]
              0x8b110210):  # add x16,x16,x17
        emit(w)
    emit(ADRP(17, here(), FS_STATE_OFF))
    for w in (0xf9001a30,   # str x16,[x17,#0x30]    vsyncs stepped
              0x1e210808,   # fmul s8,s0,s1          step × base rate
              0x52a84e10,   # mov w16,#0x42700000    60.0
              0x1e270200,   # fmov s0,w16
              0x1e201908):  # fdiv s8,s8,s0          / 60
        emit(w)
    emit(B(here(), site + 4))
    emit(0x1e201828); emit(B(here(), site + 4))   # orig: fdiv s8,s1,s0; back
    fs_put(site, [B(site, start)], 'frame ratio: the host\'s step × base rate / 60 instead of base rate / the game\'s frame rate (state page target fps; 0 = the game\'s ratio)')
    dynamic_resolution(ctx)
    render_scale(ctx)
    shadow_map(ctx)
    probe_interval(ctx)
    ground_mist(ctx)
    foliage(ctx)
    model_lod(ctx)
    shadow_cascades(ctx)

def render_scale(ctx):   # fork: v131072's own addresses (every site asserts its bytes); a rule's function at another offset (another build) gets none
    if ctx.base != 0x6e6be0: return
    here, emit = ctx.here, ctx.emit
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
    emit(cbz_w(here(), done, 17))   # not set
    emit(0x52091a30)   # eor w16,w17,#0x3f800000
    emit(cbz_w(here(), done, 16))   # 1.0: the game's own
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
    emit(cbz_w(here(), orig, 17))   # not set
    emit(0xb9001611)   # str w17,[x16,#0x14]     applied (the status stub's test)
    emit(0x52091a30)   # eor w16,w17,#0x3f800000
    emit(cbz_w(here(), orig, 16))   # 1.0: the game's own ratio
    emit(0x1e270220)   # fmov s0,w17             the host's scale instead of the controller's ratio
    assert here() == orig
    emit(0xbd4e5a81)   # ldr s1,[x20,#0xe58]     the original
    emit(B(here(), 0x31d3f3c))
    ctx.put(0x31d3f38, [B(0x31d3f38, start)], 'view scale = the host render scale (1.0 = the game\'s dynamic resolution)')
    ctx.render_scale = 1


def shadow_map(ctx):   # fork: v131072's own addresses (every site asserts its bytes); a rule's function at another offset (another build) gets none
    if ctx.base != 0x6e6be0: return
    here, emit = ctx.here, ctx.emit
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
        emit(cbnz_w(here(), here() + 8, rd))   # set: keep it
        emit(0x52860000 | rd)   # mov wN,#0x3000        the game's own
        emit(B(here(), site + 4))
        ctx.put(site, [B(site, start)], 'static shadow map size = the host size (0 = the game\'s 12288)')


# Reflection probe interval (state +0xa8, u32 written by the loader: DM_REFLECTION_INTERVAL, 0 or 1 = the game's): a quality trade for slower GPUs. The scene's cube map
# scheduler (main+0x33d6a0 on v131072; its draw main+0x268d10) keeps per probe slot (0x1c0 bytes, at [+0xef0], [+0xee8] of them) the faces done (s8 +0x1b8) and the faces to have
# done after this frame (s8 +0x1b9). Once a frame it hands out a budget of faces, [+0x268] in all and at most the byte [+0xb] per slot (1; 7 for a few frames after a scene
# change, main+0x334390): target = min(done + min([+0xb], budget left), 7). The draw renders faces done..target-1 (each a 128x128 scene render of about 220 draws); at 7 it runs
# the filter chain (main+0x84e790: 7 mips, two 6-target passes each) and the slot is released two calls later. On the balcony: a face on each of 6 frames, the filter on the 7th,
# one idle frame. The stub replaces the budget load: on frames whose number (state +0xac, the host's present count) is not a multiple of the interval the budget is 0, so no
# slot moves (target = done: no face, no filter). The cycle stretches to about 7 x interval frames; what a probe shows lags its surroundings that much longer. w9 is dead at the
# site (its next instruction loads it); x16 / x17 appear nowhere in the function
def probe_interval(ctx):
    base = ctx.others.get('probe scheduler')
    if base is None: return   # not found in this build (a red line from the locator): the game's own schedule
    here, emit = ctx.here, ctx.emit
    site = base + 0x90
    ctx.site(site, '6a6a42b9')   # ldr w10,[x19,#0x268]
    start = here()
    emit(0xb9426a6a)   # ldr w10,[x19,#0x268]   the original: the frame's face budget
    emit(ADRP(16, here(), ctx.state))
    emit(0xb940aa11)   # ldr w17,[x16,#0xa8]    the interval
    back = here() + 4 * 8
    emit(cbz_w(here(), back, 17))   # 0: the game's own
    emit(0x7100063f)   # cmp w17,#1
    emit(BEQ(here(), back))   # 1: every frame
    emit(0xb940ae10)   # ldr w16,[x16,#0xac]    frames presented
    emit(0x1ad10a09)   # udiv w9,w16,w17
    emit(0x1b11c129)   # msub w9,w9,w17,w16     frame % interval
    emit(cbz_w(here(), back, 9))   # the interval's frame: the game's budget
    emit(0x5280000a)   # mov w10,#0             other frames: no face
    assert here() == back
    emit(B(here(), site + 4))
    ctx.put(site, [B(site, start)], 'reflection probe faces only on every Nth frame (state +0xa8, DM_REFLECTION_INTERVAL; 0 or 1 = every frame, the game\'s)')
    ctx.capabilities.add('REFLECTION_INTERVAL')


# Ground mist (state +0xa4, u32 written by the loader: DM_GROUND_MIST=off, 1; 0 = the game's): a quality trade for slower GPUs. The mist over Kokiri Forest's floor is a fluid
# volume: agl's eularian_fluid_simulation computes it (about 80 dispatches a frame, 0.24 ms on a Mac mini M2 Pro) and its drawer (main+0x26b110 on v131072, called from the
# scene's draw at main+0x642ee0 with [scene+0xb80]) draws its own half-size depth (three passes), then ray-marches the volume in one task / mesh draw (fragment shader
# 5ad65c0eefd09c7f, 1.8 ms at 480x270 on the Mini) into the half-size translucent effects targets, which the effects pass cleared and the next draws add to; the drawer off saves
# about 2.2 ms a frame there. It returns at once unless its byte +0x18 is 1; the stub makes it read 0 when the mist is off. The simulation still runs: Foliage, Model and FoliageShader shaders sample its velocity (cFluidSimulationVelocity), so grass keeps moving with it.
# The draw adds into targets that are cleared and shared every frame, so it cannot run at half rate or a lower resolution on its own: off is the one level. x16 / x17
# appear nowhere in the function
def ground_mist(ctx):
    base = ctx.others.get('fluid draw')
    if base is None: return   # not found in this build: the game's mist
    here, emit = ctx.here, ctx.emit
    site = base + 0x24
    ctx.site(site, '08604039')   # ldrb w8,[x0,#0x18]
    start = here()
    emit(0x39406008)   # ldrb w8,[x0,#0x18]     the original: the drawer's enabled byte
    emit(ADRP(16, here(), ctx.state))
    emit(0xb940a611)   # ldr w17,[x16,#0xa4]    1 = off
    back = here() + 4 * 2
    emit(cbz_w(here(), back, 17))
    emit(0x52800008)   # mov w8,#0              off: the drawer reads as disabled
    assert here() == back
    emit(B(here(), site + 4))
    ctx.put(site, [B(site, start)], 'fluid volume draw (ground mist) skipped (state +0xa4, DM_GROUND_MIST=off; 0 = the game\'s)')
    ctx.capabilities.add('GROUND_MIST')


# Foliage off (state +0xb0, u32 written by the loader: DM_FOLIAGE=off, 1; 0 = the game's): a quality trade for slower GPUs. Grass, ferns, clover, the moss fur on logs and the
# other ground cover are game::foliage, one module (its singleton at main+0x4e22540 on v131072; Pack/Foliage.pack, a 248 MB "Foliage Scene Heap") with a class per model type
# (Turf, Turf1, Moss, Frost, Forest, Stone, Leaf, Flower, impostors ...), whose slot 8 says whether that type is on: the module's per-frame calc, the render list, the draws and
# the GPU calc node (main+0x2710a0, the FoliageShader compute) all ask it. The grass is drawn by the turf draw lists (main+0x2c022a0 / main+0x2c02820: task 99280b7b, mesh
# eb021183, fragment 087ef21b) and per-draw callbacks of the generic model renderer. The game turns parts of it off itself: timeline commands set the module's bytes +0x141
# (grass: the draw lists and the callbacks return before drawing) and +0x142 (the forest), and its debug word +0x2b0 has a hide bit per type in +0x2b1 (bit 0 Turf / Turf1,
# 1 Moss / Frost, 2 Stone, 3 Forest; 0 in play, read and never written). The stub, at the entry of the module's per-frame calc (main+0x2c00a40, slot 6 of its vtable: x0 is the
# module; x9..x11, x16 and x17 are free at a function's entry), sets both bytes and the four hide bits every frame while the option is on, so the game's own checks skip the
# foliage draws, the per-type calc and the foliage compute (FoliageShader f85fe649 and its siblings) from then on, whatever its timelines set. 2 (diagnostics only; the loader
# never writes it) clears them again, for an A/B inside one run. Nothing else reads the foliage outputs: the fluid simulation the grass samples runs on, and grass cutting is
# its own module (main+0x563d90)
def foliage(ctx):
    base = ctx.others.get('foliage calc')
    if base is None: return   # not found in this build: the game's foliage
    here, emit = ctx.here, ctx.emit
    ctx.site(base, '083040b9')   # ldr w8,[x0,#0x30]
    start = here()
    emit(0xb9403008)   # ldr w8,[x0,#0x30]      the original: the module's flags
    emit(ADRP(16, here(), ctx.state))
    emit(0xb940b211)   # ldr w17,[x16,#0xb0]    1 = off
    back = here() + 4 * 11
    emit(cbz_w(here(), back, 17))   # 0: the game's own
    for w in (0x7100063f,   # cmp w17,#1
              0x1a9f17e9,   # cset w9,eq           1 = off, 2 = on again (diagnostics)
              0x39050409,   # strb w9,[x0,#0x141]  grass off (the game's own)
              0x39050809,   # strb w9,[x0,#0x142]  forest off (the game's own)
              0xb942b00a,   # ldr w10,[x0,#0x2b0]
              0x12146d4a,   # and w10,w10,#0xfffff0ff
              0x4b0903eb,   # neg w11,w9
              0x12180d6b,   # and w11,w11,#0xf00   the hide bits of Turf / Turf1, Moss / Frost, Stone, Forest
              0x2a0b014a,   # orr w10,w10,w11
              0xb902b00a):  # str w10,[x0,#0x2b0]
        emit(w)
    assert here() == back
    emit(B(here(), base + 4))
    ctx.put(base, [B(base, start)], 'foliage off: the module\'s grass / forest disables and type hide bits set each frame (state +0xb0, DM_FOLIAGE=off; 0 = the game\'s)')
    ctx.capabilities.add('FOLIAGE')


# Model level of detail (state +0xb4, float written by the loader: DM_MODEL_LOD, above 1 up to 8; 0 = the game's): a quality trade for slower GPUs. Each model picks its mesh level once a
# frame from its level data (model +0x78 → +0x18) and the graphics module's settings (the object of the frame update main+0x31d3200), in one of two ways:
#  - by size on screen: the model's projected size (a fraction of the screen height) x 1080 (the module's +0x1510, a constant: the game's own render size never enters) is divided
#    by the level scale of its kind (+0x1518[kind]) x the module's pixel scale (+0x1514, which the timeline command OneshotSetPixelScaleForModelLod sets), and the level is the
#    first whose threshold (level data +0x48[i]) that size still reaches. The stubs multiply that divisor by the host's factor, so a model takes each lower level at 1/factor
#    of the size on screen it took it at, as if it were that many times farther away;
#  - by distance: the module's start distance coefficient (+0xd90: ModelLodParam's LodStartDistCoefForHandheld, 0.8, or ForConsole, 1.0, which the frame update copies by the
#    operation mode) scales the level data's start distance (+0x40); the stubs divide the coefficient by the factor, so the lower levels start that many times nearer, as
#    handheld mode already does at 0.8.
# The choice is written out five times: three inlined copies in the model scene's per-model calc (main+0x7bb80 on v131072, its callers main+0x795a0 and main+0x798a0; the
# copies the game ran on Link's balcony, about 55 choices by size and 24 by distance a frame, counted by diagnostic stubs), and the module's own level function (its vtable's
# main+0x31d48b0) with main+0x31d4d80, the caller that inlines it when the slot holds it (neither ran there). Sites and the registers each stub may use:
#  - the calc's size copies: ldr s3,[x20,#0x1514] (the pixel scale) x the factor; s4 and x11 are written by the next two instructions before anything reads them;
#  - the calc's distance copies: ldr s4,[x20,#0xd90] / the factor; s5 and x8 are written by the next instructions before anything reads them, and the flags of the fcmp before the
#    site, which an fcsel after it reads, are left alone (cbz, fmov and fdiv set none);
#  - the level function and its caller: fmul s3,s4,s3 (scale x pixel scale) x the factor and ldr s5,[xN,#0xd90] / the factor; s4 is dead after the fmul, and s7, x16 and x17
#    appear nowhere before their next write in either function; no flags are live there.
# The levels are chosen for 1080 lines whatever size the game renders (864 at its full size, 432 at DM_RENDER_SCALE=0.5), so at 0.5 a factor of 2.5 gives about the
# triangles a pixel the game has at its full size. Apple GPUs shade a 2x2 quad for every pixel a triangle touches, so thin and small triangles cost fragment work too: the
# Great Deku Tree's beard of hanging roots is most of its pass
model_calc_size, model_calc_distance = (0x26c4, 0x8a80, 0xabe4), (0x34a0, 0x91bc, 0xb9c4)   # in the model scene calc: its three copies of the choice
def model_lod(ctx):
    calc, func, inline = ctx.others.get('model calc'), ctx.others.get('model lod'), ctx.others.get('model lod inline')
    if calc is None or func is None or inline is None: return   # not all found in this build: the game's own level of detail
    here, emit = ctx.here, ctx.emit
    def stub(site, original, words, reason):   # the original instruction, then the words (which end at the point the factor is 0 jumps to), then back
        ctx.site(site, original.to_bytes(4, 'little').hex())
        start = here()
        emit(original)
        for w in words(here()): emit(w)
        emit(B(here(), site + 4))
        ctx.put(site, [B(site, start)], reason)
    for off in model_calc_size:
        stub(calc + off, 0xbd551683,   # ldr s3,[x20,#0x1514]   the module's pixel scale
             lambda at: [ADRP(11, at, ctx.state),
                         0xb940b56b,   # ldr w11,[x11,#0xb4]   the factor (float bits)
                         cbz_w(at + 8, at + 20, 11),   # 0: the game's own
                         0x1e270164,   # fmov s4,w11
                         0x1e240863],   # fmul s3,s3,s4        the pixel scale x the factor
             'model level by size on screen (model scene calc): the pixel scale x the host factor (state +0xb4, DM_MODEL_LOD; 0 = the game\'s)')
    for off in model_calc_distance:
        stub(calc + off, 0xbd4d9284,   # ldr s4,[x20,#0xd90]   the start distance coefficient
             lambda at: [ADRP(8, at, ctx.state),
                         0xb940b508,   # ldr w8,[x8,#0xb4]
                         cbz_w(at + 8, at + 20, 8),
                         0x1e270105,   # fmov s5,w8
                         0x1e251884],   # fdiv s4,s4,s5        the coefficient / the factor
             'model level by distance (model scene calc): the start distance coefficient / the host factor (state +0xb4, DM_MODEL_LOD; 0 = the game\'s)')
    for base, size_site, dist_site, module in ((func, 0x14c, 0x1e4, 21), (inline, 0x228, 0x2a4, 19)):
        stub(base + size_site, 0x1e230883,   # fmul s3,s4,s3   the level's scale x the pixel scale
             lambda at: [ADRP(16, at, ctx.state),
                         0xb940b611,   # ldr w17,[x16,#0xb4]
                         cbz_w(at + 8, at + 20, 17),
                         0x1e270224,   # fmov s4,w17
                         0x1e240863],   # fmul s3,s3,s4
             'model level by size on screen (level function): the divisor x the host factor (state +0xb4, DM_MODEL_LOD; 0 = the game\'s)')
        stub(base + dist_site, 0xbd4d9005 | (module << 5),   # ldr s5,[x21 or x19,#0xd90]
             lambda at: [ADRP(16, at, ctx.state),
                         0xb940b611,   # ldr w17,[x16,#0xb4]
                         cbz_w(at + 8, at + 20, 17),
                         0x1e270227,   # fmov s7,w17
                         0x1e2718a5],   # fdiv s5,s5,s7
             'model level by distance (level function): the start distance coefficient / the host factor (state +0xb4, DM_MODEL_LOD; 0 = the game\'s)')
    ctx.capabilities.add('MODEL_LOD')

# Shadow cascades (state +0xb8, u32 written by the loader: DM_SHADOW_CASCADES, 1 or 2; 0 = the game's): a quality trade for slower GPUs. The dynamic depth shadow of the sun is
# a cascade of depth maps (1000x1000 Depth16 each on the Apple TV's run 18, one pass a cascade); their number is gsys ModelSceneConfigParam's DepthShadowCascadeNum0 (3 in
# /gsys/ModelSceneConfigParam/Main; its splits DepthShadowNear00..03 2, 32, 64, 200 m). The parameter binder (main+0x35667c0 on v131072) reads each key from the file into its
# field as it visits it; the stub, right after the visit of DepthShadowCascadeNum0 (field +0x394), lowers the value to the host's, so the shadow setup made from the parameters
# has fewer cascades: the nearest ones are kept, and shadows end at the last kept split. Read once, when the parameters load (at boot), so it cannot change in a running game.
# x8 and x9 are written again by the binder before they are read, and the stub ends on the original cmp, so the flags are the binder's
def shadow_cascades(ctx):
    base = ctx.others.get('scene config binder')
    if base is None: return   # not found in this build: the game's cascades
    here, emit = ctx.here, ctx.emit
    site = base + 0x2408
    ctx.site(site, '1f040071')   # cmp w0,#1   after the visit of DepthShadowCascadeNum0
    start = here()
    emit(0xb9439689)   # ldr w9,[x20,#0x394]   the cascades the file gave
    emit(ADRP(8, here(), ctx.state))
    emit(0xb940b908)   # ldr w8,[x8,#0xb8]     the host's number
    done = here() + 4 * 4
    emit(cbz_w(here(), done, 8))   # 0: the game's own
    emit(0x6b08013f)   # cmp w9,w8
    emit(0x1a898109)   # csel w9,w8,w9,hi      the file's above the host's: the host's
    emit(0xb9039689)   # str w9,[x20,#0x394]
    assert here() == done
    emit(0x7100041f)   # cmp w0,#1             the original
    emit(B(here(), site + 4))
    ctx.put(site, [B(site, start)], 'shadow cascades: DepthShadowCascadeNum0 lowered to the host\'s number as the parameters load (state +0xb8, DM_SHADOW_CASCADES; 0 = the game\'s)')
    ctx.capabilities.add('SHADOW_CASCADES')


# The game's dynamic resolution (game__gfx__DynamicResolutionParam: LoadThreshold, ReduceCounterMax, IncreaseCounterMax and a list of levels, each a ResolutionReduceScale and a
# Priority; on v131072 levels 0..9 at 0.75..0.333 of 2048x1152, 1536x864 to 683x384). Its update (main+0x805aa0) reads the frame's GPU load (about 0.2 ms a unit) into +0x8, subtracts
# its small model of the fixed costs and divides the rest by the square of the current scale: it takes the rest of the frame's cost to grow with the pixel count, as on the Switch 2
# its constants were tuned for. The level function (main+0x8065e0) adds that back times each level's scale squared and returns the best level under the threshold (+0x10, 83 = about
# 16.4 ms). On Apple GPUs this game's cost hardly depends on the resolution (mesh, compute and the upscaler's fixed 2048x1152 dominate): 683x384 cost 14.3 ms and 1536x864 14.7 ms on
# an M4 Pro, yet at 683x384 the extrapolation put 1536x864 at about 300 units against the 83 it allows, so the controller sat at its floor for good (game note, Dynamic resolution).
# The stub replaces the level function. With DM_DYNAMIC_RESOLUTION 0 (the default; state +0x40 0) it returns 0: full resolution. With 1 it climbs on what was measured at each
# level, with no model of how the cost grows: one level down when the load (+0x8) has been over the threshold for 8 calls in a row, and that level is marked as not fitting; one level
# up when the load fits and the level above was never measured, fitted when it was last measured, or was measured more than 600 calls (about 10 s) ago; else the current level
# (+0x174). Nothing is decided or recorded until a level has held 8 calls: the load is read a few frames late, so before that it may be the previous level's. The 8 calls over in a
# row keep a single slow frame, or the first frames at a new size (its render targets), from marking a level that fits (on the full library at level 1: one burst to 90 against loads
# of 77-80 at levels 2 and 1). The game's counters still pace the steps (down after ReduceCounterMax frames, up after IncreaseCounterMax); its level count (+0x1a0) is the floor.
# The memory is in the state page: +0x200 calls, +0x204 the last call's level, +0x208 calls at it, +0x20c calls over in a row, +0x210 the load measured at each level (16 floats),
# +0x250 the call it was measured at (0 = never). Run against a model of the update (a level moves after the stub asked 5 times up or 2 times down; the load two frames late): a load
# of 70 at every level climbs from the floor to full size in 9 steps, as does Ocarina's measured 72-80 with a spike every 37 frames and a burst after each change; a load that grows
# with the pixel count settles at the highest level that fits and tries the one above once per 600 calls; a scene that gets lighter climbs again, a heavier one steps down.
# The function is a leaf: x2..x11, x16, x17 and s0..s2 are free, w0 its only result (the original also stores its predicted cost at +0x18, which only it and the update's own
# decision read). The update's fingerprint is required too: +0x8 and +0x174 are its fields
drs_controller = (   # drs_stub.s, assembled with clang; x0 the controller, x16 the state page (the ADRP before it)
    0xb9404211, 0x35000071, 0x2a1f03e0, 0xd65f03c0,                                                   # off (state +0x40 0): level 0
    0xbd400800, 0xbd401001, 0xb9417402, 0xb941a003, 0x7100005f, 0x1a9fa042, 0x528001e9, 0x6b09005f,   # load, threshold, level (0..15), count
    0x1a89d042, 0xb9420204, 0x11000484, 0xb9020204, 0xb9420605, 0xb9420a06, 0x6b0200bf, 0x1a8617e6,   # calls + 1; calls at this level
    0xb9020602, 0xb9020a06, 0x35000046, 0xb9020e1f, 0x91084207, 0x91094208, 0x710020df, 0x5400040b,   # a new level: none over; under 8 calls: stay
    0x1e212000, 0x540001ad, 0xb9420e0b, 0x1100056b, 0xb9020e0b, 0x7100217f, 0x5400032b,               # over: under 8 in a row, stay
    0xbc2258e0, 0xb8225904, 0x51000469, 0x1100044a, 0x6b09015f, 0x1a89d140, 0xd65f03c0,               # 8 in a row: record it, down one (to the floor)
    0xb9020e1f, 0xbc2258e0, 0xb8225904, 0x34000182, 0x51000449, 0xb869590a, 0x340000ea, 0x4b0a008a,   # fits: record it; at 0 stay; the level above's record
    0x7109615f, 0x54000088, 0xbc6958e2, 0x1e212040, 0x540000aa, 0x2a0903e0, 0xd65f03c0,               # never, stale or fitting: up one
    0x2a1f03e0, 0xd65f03c0, 0x2a0203e0, 0xd65f03c0)                                                   # 0; or stay
def dynamic_resolution(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    site = ctx.others.get('dynamic resolution')
    if site is None or ctx.others.get('dynamic resolution update') is None: return   # not both found in this build (a red line from the locator): the game's own dynamic resolution
    fs_site(site, '017c40bd')   # ldr s1,[x0,#0x7c]
    start = here(); emit(ADRP(16, here(), FS_STATE_OFF))
    for w in drs_controller: emit(w)
    fs_put(site, [B(site, start)], 'dynamic resolution level: 0 (full resolution), or with state +0x40 (DM_DYNAMIC_RESOLUTION) a climb on the load measured at each level')
    ctx.capabilities.add('DYNAMIC_RESOLUTION')

MATCH_FRAME_STEP = {'main': [
    {'name': 'frame ratio from the host\'s step', 'size': 0x9b4, 'fingerprints': ['6ae2aff5344d14568e4dbaf93455e2d8278384bf892ed6c6eca87fef98fbcd1d'], 'stub': frame_step,   # v131072 main+0x6e6be0
     'others': {'dynamic resolution': {'size': 0x294, 'fingerprints': ['7af6ceb0aedf8e0c17dc08ce17fcd6a7cba6d394a0d09e3b504c6d668dc418e7']},   # v131072 main+0x8065e0
                'dynamic resolution update': {'size': 0xb24, 'fingerprints': ['5a423697838976baf286cffa5e2ceef0d4e037abbcd9d371e90e9e702d61b3d4']},   # main+0x805aa0
                'probe scheduler': {'size': 0xa84, 'fingerprints': ['1cf03d90dce3429a92cc48b83ac150ef3dbe9cd4b00a4c494d1eb6a69086df6b']},   # main+0x33d6a0
                'fluid draw': {'size': 0x13f8, 'fingerprints': ['c7b343dde31d4f1d1c315bdbb0db303d16282868356312ec51b2a83a83e6b3f8']},   # main+0x26b110
                'foliage calc': {'size': 0x6f8, 'fingerprints': ['34cac4f1d8c1a00d12efcb767c1213da3d6c5d692cb61254da2cb1b926d49891']},   # main+0x2c00a40
                'model calc': {'size': 0xc374, 'fingerprints': ['53bcd5b0e1917420e07d170b994836b48554e140292c6b4cbe1640f7e8cfa791']},   # main+0x7bb80
                'model lod': {'size': 0x4a8, 'fingerprints': ['739352a7c0fe91d8a0ab0ab62096f5735eafd8577e8b907136f0904367e65440']},   # main+0x31d48b0
                'model lod inline': {'size': 0x860, 'fingerprints': ['9689ff1833cbbb9e47ffd604d9e1bca6ef31a73c2f7520492e9681ca59397461']},   # main+0x31d4d80
                'scene config binder': {'size': 0xbe1c, 'fingerprints': ['9a6c3c997131c75bd152e7de43e419351d80f8dd07169234009d6fee266f707f']}}},   # main+0x35667c0
]}

BINDING = [
    {'what': 'frame ratio from the host\'s step', 'now': 'game', 'goal': 'game', 'purpose': 'frame rate',
     'why': "the game's own frame-ratio division, found by its function's fingerprint on any build that keeps the function",
     'checked': 'v131072 main: one function with this fingerprint, the site and its free registers read by disassembly (2026-11-08)'},
    {'what': 'dynamic resolution: full size, or a climb on the load measured at each level', 'now': 'game', 'goal': 'game', 'purpose': 'rendering',
     'why': "the game's own dynamic-resolution level function and update, found by their functions' fingerprints on any build that keeps both; switchable (DM_DYNAMIC_RESOLUTION)",
     'checked': 'v131072 main: one function with each fingerprint (the level function a leaf, x2..x11 / x16 / x17 / s0..s2 free), its callers, the update and the controller fields read by disassembly, the fields read in play (2026-11-08); the climb run natively against a model of the update and in play to full size (2026-11-09)'},
    {'what': 'reflection probe faces only on every Nth frame (DM_REFLECTION_INTERVAL)', 'now': 'game', 'goal': 'game', 'purpose': 'rendering',
     'why': "the face budget load of the game's cube map scheduler, found by the scheduler function's fingerprint on any build that keeps it; switchable, off by default",
     'checked': 'v131072 main: one function with this fingerprint; its slots, budget and the draw read by disassembly, the call paths of the probe passes traced in play (2026-11-09)'},
    {'what': 'ground mist off: the fluid volume draw skipped (DM_GROUND_MIST)', 'now': 'game', 'goal': 'game', 'purpose': 'rendering',
     'why': "the enabled byte of the game's fluid volume drawer, found by its function's fingerprint on any build that keeps it; switchable, off by default",
     'checked': 'v131072 main: one function with this fingerprint; the mist draw and the simulation dispatches traced to it in play (2026-11-09)'},
    {'what': 'foliage off: the foliage module\'s grass / forest disables and type hide bits set each frame (DM_FOLIAGE)', 'now': 'game', 'goal': 'game', 'purpose': 'rendering',
     'why': "the foliage module's per-frame calc, found by its function's fingerprint on any build that keeps it; the flags are the module's own (its timeline disables and debug hide bits); switchable, off by default",
     'checked': 'v131072 main: one function with this fingerprint (slot 6 of the module vtable); the flags\' readers (turf draw lists, per-draw callbacks, the type classes\' slot 8, the GPU calc node) read by disassembly; each gate switched in play on the balcony with shots and the encoders per phase (2026-11-10)'},
    {'what': 'model level of detail: the size on screen and the start distance seen through a factor (DM_MODEL_LOD)', 'now': 'game', 'goal': 'game', 'purpose': 'rendering',
     'why': "the graphics module's pixel scale and start distance coefficient where the game's model scene calc and its level function read them, found by the three functions' fingerprints on any build that keeps them; switchable, off by default",
     'checked': 'v131072 main: one function with each fingerprint; the level choice read by disassembly (its three copies in the model scene calc and the module\'s level function), the free registers at each site; counters in the stubs in play on the balcony: about 55 size and 24 distance choices a frame in the calc, none in the level function (2026-11-12)'},
    {'what': 'shadow cascades: DepthShadowCascadeNum0 lowered as the parameters load (DM_SHADOW_CASCADES)', 'now': 'game', 'goal': 'game', 'purpose': 'rendering',
     'why': "the visit of DepthShadowCascadeNum0 in gsys ModelSceneConfigParam's binder, found by its function's fingerprint on any build that keeps it; switchable, off by default",
     'checked': 'v131072 main: one function with this fingerprint, the key, field offset and default read by disassembly; one cascade pass a frame instead of three in play on the balcony (2026-11-12)'},
    {'what': 'view scale = the host render scale (DM_RENDER_SCALE)', 'now': 'build', 'goal': 'game', 'purpose': 'rendering',
     'why': "the 3D views' scale store and the dynamic-resolution status in the graphics module's frame update, at v131072's offsets (the match rule's function is at main+0x6e6be0 there)",
     'blocked': 'no function-matched form yet; sits beside the frame ratio stub, which is matched'},
    {'what': 'static shadow map size (DM_SHADOW_MAP_SIZE)', 'now': 'build', 'goal': 'game', 'purpose': 'rendering',
     'why': "the literal 12288 (mov wN,#0x3000) of the fine static depth shadow texture, at v131072's offsets (the match rule's function is at main+0x6e6be0 there)",
     'blocked': 'no function-matched form yet; sits beside the frame ratio stub, which is matched'},
]
