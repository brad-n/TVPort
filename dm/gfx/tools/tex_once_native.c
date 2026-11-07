// The native half of dm/gfx/tools/tex_once.py: a Yaz0 encoder that writes the stream (the spike's yaz0_enc.c only counted bytes).
// Hash chains over 3-byte keys, a 4096-byte window, one-step lazy matching. Built by tex_once.py with clang into a small library loaded with ctypes.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define WIN 4096
#define RING 8192            // power of two > WIN: prev[] is a ring over the last RING positions
#define MAXLEN 273
#define HBITS 15

static inline uint32_t hash3(const uint8_t *p) { return (((uint32_t)p[0] << 8) ^ ((uint32_t)p[1] << 4) ^ ((uint32_t)p[2] * 0x9E5u)) & ((1u << HBITS) - 1); }

typedef struct { int32_t head[1 << HBITS]; int32_t prev[RING]; size_t ins; } hc_t;

static inline void insert_upto(hc_t *h, const uint8_t *s, size_t n, size_t upto) {   // insert positions [ins, upto)
    while (h->ins < upto) {
        size_t p = h->ins++;
        if (p + 2 < n) { uint32_t k = hash3(s + p); h->prev[p & (RING - 1)] = h->head[k]; h->head[k] = (int32_t)p; }
    }
}

static inline size_t find_match(hc_t *h, const uint8_t *s, size_t n, size_t i, int chain, size_t *dist) {
    if (i + 2 >= n) return 0;
    size_t mx = n - i < MAXLEN ? n - i : MAXLEN, best = 0;
    int32_t c = h->head[hash3(s + i)];
    for (int k = 0; c >= 0 && k < chain; k++) {
        size_t d = i - (size_t)c;
        if (d > WIN) break;
        size_t l = 0;
        if (s[c] == s[i]) { while (l < mx && s[(size_t)c + l] == s[i + l]) l++; }
        if (l > best) { best = l; *dist = d; if (l == mx) break; }
        int32_t nx = h->prev[(size_t)c & (RING - 1)];
        if (nx >= c) break;
        c = nx;
    }
    return best >= 3 ? best : 0;
}

// Encodes s[0..n) as a Yaz0 stream (16-byte header: "Yaz0", n big-endian, 8 zero bytes) into dst[0..cap). Returns the stream size, or -1 when it does not fit cap (or n >= 2^31)
int64_t dm_yaz0_pack(const uint8_t *s, size_t n, uint8_t *dst, size_t cap, int chain) {
    if (n >= ((size_t)1 << 31) || cap < 16) return -1;
    hc_t *h = malloc(sizeof *h);
    if (!h) return -1;
    memset(h->head, 0xff, sizeof h->head); memset(h->prev, 0xff, sizeof h->prev); h->ins = 0;
    memcpy(dst, "Yaz0", 4);
    dst[4] = (uint8_t)(n >> 24); dst[5] = (uint8_t)(n >> 16); dst[6] = (uint8_t)(n >> 8); dst[7] = (uint8_t)n;
    memset(dst + 8, 0, 8);
    size_t o = 16, i = 0, fp = 0; int bits = 0; int64_t ret = -1;
#define NEED(k) do { if (o + (k) > cap) goto done; } while (0)
    while (i < n) {
        if (!bits) { NEED(1); fp = o; dst[o++] = 0; bits = 8; }
        insert_upto(h, s, n, i);
        size_t dist = 0, len = find_match(h, s, n, i, chain, &dist);
        if (len >= 3 && len < 64 && i + 1 < n) {            // lazy: is the next position's match longer?
            size_t d2 = 0;
            insert_upto(h, s, n, i + 1);
            size_t l2 = find_match(h, s, n, i + 1, chain, &d2);
            if (l2 > len + 1) len = 0;
        }
        if (len >= 3) {
            if (len <= 0x11) { NEED(2); dst[o++] = (uint8_t)(((len - 2) << 4) | ((dist - 1) >> 8)); dst[o++] = (uint8_t)((dist - 1) & 255); }
            else { NEED(3); dst[o++] = (uint8_t)((dist - 1) >> 8); dst[o++] = (uint8_t)((dist - 1) & 255); dst[o++] = (uint8_t)(len - 0x12); }
            i += len;
        } else {
            NEED(1); dst[fp] |= (uint8_t)(0x80 >> (8 - bits)); dst[o++] = s[i]; i++;
        }
        bits--;
    }
    ret = (int64_t)o;
done:
    free(h);
    return ret;
}
