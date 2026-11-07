// Encode throughput of the BC-to-ASTC transcoder (decode of the BC plane + astc-encoder FASTEST), single worker against two. Not a test: prints numbers; no sanitizers.
// There is no real BC data in the repository, so the planes are synthetic: a BC1 compression (min/max endpoints) of a procedural picture with gradients, edges and fine noise (a typical colour
// map's mix of smooth and busy blocks), and BC7 mode-6 blocks of pure noise (the worst case for the encoder).
#include "../tex/nvn_astc_cache.m"
#include <pthread.h>
static uint8_t *synthetic_bc1(unsigned w, unsigned h, unsigned seed) {
    uint8_t *rgb = malloc((size_t)w * h * 3);
    uint32_t st = seed * 2654435761u + 7;
    for (unsigned y = 0; y < h; y++) for (unsigned x = 0; x < w; x++) {
        float fx = x + seed * 13.0f, fy = y;
        float base = 0.5f + 0.25f * sinf(fx / 97.0f) + 0.2f * sinf(fy / 61.0f + fx / 211.0f);
        float edge = (((x / 53) + (y / 71)) & 1) ? 0.15f : 0.0f;
        float ring = fabsf(sqrtf((fx - 700) * (fx - 700) + (fy - 500) * (fy - 500)) - 300.0f) < 6.0f ? 0.4f : 0.0f;
        st = st * 1664525u + 1013904223u; float noise = ((st >> 24) / 255.0f - 0.5f) * 0.12f;
        float v = base + edge + ring + noise;
        uint8_t *p = rgb + ((size_t)y * w + x) * 3;
        float c[3] = {v, v * 0.8f + 0.1f * sinf(fx / 29.0f), v * 0.6f + 0.2f};
        for (int i = 0; i < 3; i++) p[i] = (uint8_t)fminf(255.0f, fmaxf(0.0f, c[i] * 255.0f));
    }
    uint8_t *bc = malloc((size_t)w / 4 * (h / 4) * 8);
    for (unsigned by = 0; by < h / 4; by++) for (unsigned bx = 0; bx < w / 4; bx++) {
        int lo[3] = {255, 255, 255}, hi[3] = {0, 0, 0};
        for (int i = 0; i < 16; i++) { const uint8_t *p = rgb + (((size_t)by * 4 + i / 4) * w + bx * 4 + i % 4) * 3; for (int c = 0; c < 3; c++) { if (p[c] < lo[c]) lo[c] = p[c]; if (p[c] > hi[c]) hi[c] = p[c]; } }
        uint16_t c0 = (uint16_t)((hi[0] >> 3) << 11 | (hi[1] >> 2) << 5 | hi[2] >> 3), c1 = (uint16_t)((lo[0] >> 3) << 11 | (lo[1] >> 2) << 5 | lo[2] >> 3);
        if (c0 < c1) { uint16_t t = c0; c0 = c1; c1 = t; }
        if (c0 == c1) c0 = c1 + 1;
        int pal[4][3];
        uint16_t cs[2] = {c0, c1};
        for (int k = 0; k < 2; k++) { pal[k][0] = ((cs[k] >> 11) & 31) * 255 / 31; pal[k][1] = ((cs[k] >> 5) & 63) * 255 / 63; pal[k][2] = (cs[k] & 31) * 255 / 31; }
        for (int c = 0; c < 3; c++) { pal[2][c] = (2 * pal[0][c] + pal[1][c]) / 3; pal[3][c] = (pal[0][c] + 2 * pal[1][c]) / 3; }
        uint32_t idx = 0;
        for (int i = 0; i < 16; i++) {
            const uint8_t *p = rgb + (((size_t)by * 4 + i / 4) * w + bx * 4 + i % 4) * 3; int best = 0, bd = 1 << 30;
            for (int k = 0; k < 4; k++) { int d = 0; for (int c = 0; c < 3; c++) d += (p[c] - pal[k][c]) * (p[c] - pal[k][c]); if (d < bd) { bd = d; best = k; } }
            idx |= (uint32_t)best << (2 * i);
        }
        uint8_t *o = bc + ((size_t)by * (w / 4) + bx) * 8;
        memcpy(o, &c0, 2); memcpy(o + 2, &c1, 2); memcpy(o + 4, &idx, 4);
    }
    free(rgb);
    return bc;
}
static uint8_t *noise_bc7(unsigned w, unsigned h, unsigned seed) {
    size_t n = (size_t)w / 4 * (h / 4) * 16; uint8_t *d = malloc(n); uint32_t st = seed * 2654435761u + 1;
    for (size_t i = 0; i < n; i++) { st = st * 1664525u + 1013904223u; d[i] = st >> 24; }
    for (size_t i = 0; i < n; i += 16) d[i] = (d[i] & ~0x7fu) | 0x40u;
    return d;
}
typedef struct { uint32_t format; unsigned w, h, block, slot, first, count; uint8_t **planes; size_t astc; } job_t;
static void *run(void *arg) {
    job_t *j = arg; nvn_bc_format_info info; nvn_bc_format(j->format, &info);
    uint8_t *out = malloc(j->astc);
    for (unsigned i = j->first; i < j->first + j->count; i++) if (encode_plane(j->slot, j->format, j->planes[i], j->w, j->h, j->block, &info, out)) { fprintf(stderr, "encode failed\n"); exit(1); }
    free(out); return NULL;
}
static double bench(uint32_t format, uint8_t **planes, unsigned n, unsigned w, unsigned h, unsigned block, unsigned threads) {
    size_t astc = (size_t)((w + block - 1) / block) * ((h + block - 1) / block) * 16;
    pthread_t th[4]; job_t jobs[4];
    // warm the contexts (allocation of the codec) outside the timing
    { job_t warm = {format, w, h, block, 1, 0, 1, planes, astc}; run(&warm); for (unsigned t = 1; t < threads; t++) { warm.slot = 1 + t; run(&warm); } }
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    for (unsigned t = 0; t < threads; t++) { jobs[t] = (job_t){format, w, h, block, 1 + t, t * (n / threads), n / threads, planes, astc}; pthread_create(&th[t], NULL, run, &jobs[t]); }
    for (unsigned t = 0; t < threads; t++) pthread_join(th[t], NULL);
    return (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0) / 1e9;
}
int main(void) {
    enum { W = 1024, H = 1024, N = 8 };
    struct { const char *name; uint32_t format; } sets[] = {{"BC1 synthetic picture", 0x42}, {"BC7 mode-6 noise (worst case)", 0x4d}};
    printf("%-30s %5s %7s %10s %12s %14s\n", "plane set (1024x1024 x 8)", "block", "workers", "seconds", "Mtexel/s", "MB/s RGBA8");
    for (int s = 0; s < 2; s++) {
        uint8_t *planes[N];
        for (unsigned i = 0; i < N; i++) planes[i] = s == 0 ? synthetic_bc1(W, H, i) : noise_bc7(W, H, i);
        for (unsigned block = 4; block <= 6; block += 2) for (unsigned threads = 1; threads <= 2; threads++) {
            double sec = bench(sets[s].format, planes, N, W, H, block, threads), texels = (double)W * H * N;
            printf("%-30s %5ux%u %7u %10.2f %12.2f %14.1f\n", sets[s].name, block, block, threads, sec, texels / sec / 1e6, texels * 4 / sec / 1048576.0);
        }
        for (unsigned i = 0; i < N; i++) free(planes[i]);
    }
    return 0;
}
