// nn::vi::ListDisplays fills one DisplayInfo (0x60 bytes): name "Default", a layer limit at +0x40, then the layer count limit and the largest layer's width and height at
// +0x48. Star Fox sizes its picture by the largest layer: with the limits left at zero (build 1660, the memcpy behind a comment) it drew at 1x1 and showed black
#include "../../gfx/hle_vi.c"
#include <assert.h>

uint64_t dm_nvn_frame_count(void) { return 0; }
void mtl_present_progress(uint64_t *q, uint64_t *d) { *q = 0; *d = 0; }
double mtl_presented_time(uint64_t n) { (void)n; return 0; }
void mtl_present_layer(uint32_t w, uint32_t h) { (void)w; (void)h; }
uint64_t guest_ns(void) { return 0; }
uint64_t now_ns(void) { return 0; }
int dm_sdk_ounce(void) { return 0; }
static int g_op = 1;
int dm_opmode(void) { return g_op; }

static void check(int op) {
    uint8_t d[2][0x60]; memset(d, 0xa5, sizeof d); g_op = op;
    assert(h_vi_ListDisp(d, 2) == 1);                                 // one display, whatever the buffer holds
    assert(!strcmp((char *)d[0], "Default") && d[0][0x40] == 1);
    uint64_t lim[3]; memcpy(lim, d[0] + 0x48, sizeof lim);
    assert(lim[0] == 1 && lim[1] == 1920 && lim[2] == 1080);          // a layer, the largest 1920x1080 (DM_TV_OUTPUT's default)
    assert(d[1][0] == 0xa5);                                          // nothing written past it
}

int main(void) {
    uint8_t d[0x60];
    assert(h_vi_ListDisp(NULL, 1) == 0 && h_vi_ListDisp(d, 0) == 0);  // no buffer, no room
    check(1); check(0);                                                // docked and handheld
    puts("vi ListDisplays: one display \"Default\" with its layer limits (1 layer, 1920x1080), docked and handheld");
    return 0;
}
