// The Apple TV's picture size (front_ios.m): its drawable at most DM_TV_MAX_WIDTH pixels across, and the display a docked Switch 2 game is told it has (front_display_pixels,
// hle_vi.c QueryDisplayBufferMaxResolution) capped the same way. A 4K TV otherwise gets a 3840x2160 drawable for a picture the game renders at 1920x1080 at most in handheld mode
// (one more full-screen upscale a frame, and three 4K drawables, about 100 MB against 25 MB), and a docked Switch 2 game renders its output at 4K. The TV's display hardware
// scales the layer to the screen. Plain C, so the tests build it on the Mac (dm/ios/tests/test_tv_display_cap.py)
#pragma once
#include <stdlib.h>

// DM_TV_MAX_WIDTH: unset, empty or not a whole number ≥ 0: 1920; 0: the screen's own pixels; below 640 is raised to 640
static inline int dm_tv_max_width(const char *env) {
    if (!env || !*env) return 1920;
    char *end; long v = strtol(env, &end, 10);
    if (*end || v < 0 || v > 16384) return 1920;
    return v == 0 ? 0 : v < 640 ? 640 : (int)v;
}

// A screen of w x h pixels (landscape) under a cap of max_w pixels across: the same shape, at most max_w wide (rounded); max_w 0 keeps it
static inline void dm_cap_display(int *w, int *h, int max_w) {
    if (max_w > 0 && *w > max_w) { *h = (int)(((long long)*h * max_w + *w / 2) / *w); *w = max_w; }
}
